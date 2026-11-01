defmodule Shoestring.CLI.AsksTest do
  @moduledoc """
  `shoestring asks`: the person lists what workers wait on them for and
  answers in a terminal; an agent cannot answer as them. The test process
  stands in for the waiting worker session. No service, provider or network.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.CLI.Commands.Asks
  alias Shoestring.CLI.Refusal
  alias Shoestring.PermissionAsks
  alias Shoestring.PermissionAsks.Ask

  defp context(opts \\ []) do
    %{
      shell: Mix.Shell.Process,
      with_repo: fn fun -> fun.(Repo) end,
      cwd: File.cwd!(),
      interactive?: fn -> Keyword.get(opts, :interactive, true) end,
      env: fn "SHOESTRING_SESSION" -> Keyword.get(opts, :session, "s1") end
    }
  end

  defp waiting!(session) do
    ask =
      Repo.insert!(%Ask{
        goal_id: Ecto.UUID.generate(),
        run_id: "run-1",
        session_id: session,
        agent: "builder",
        provider: "codex",
        command: "/bin/zsh -lc 'curl https://example.invalid'",
        reason: "Fetch notes"
      })

    {:ok, _} = Registry.register(PermissionAsks.registry(), ask.id, nil)
    ask
  end

  test "the session's waiting asks are listed with how to answer them" do
    ask = waiting!("s1")
    _other = waiting!("s2")
    short = String.slice(ask.id, 0, 8)

    Asks.run([], context())
    assert_receive {:mix_shell, :info, [text]}
    assert text =~ "builder (codex) asks to run:"
    assert text =~ "$ /bin/zsh -lc 'curl https://example.invalid'"
    assert text =~ "why: Fetch notes"
    assert text =~ "shoestring asks allow #{short}"
    refute_receive {:mix_shell, :info, _}

    # An ask whose worker session is gone is not shown: nobody waits on it.
    Repo.insert!(%Ask{
      goal_id: Ecto.UUID.generate(),
      run_id: "gone",
      session_id: "s1",
      provider: "codex",
      command: "true"
    })

    Asks.run(["--json", "--all"], context())
    assert_receive {:mix_shell, :info, [json]}
    assert length(Jason.decode!(json)) == 2
    assert [%{id: id}] = PermissionAsks.pending("s1")
    assert id == ask.id
  end

  test "the person allows or denies in a terminal; an agent without one cannot" do
    ask = waiting!("s1")
    short = String.slice(ask.id, 0, 8)

    assert_raise Refusal, ~r/person's decision/, fn ->
      Asks.run(["allow", short], context(interactive: false))
    end

    assert Repo.get(Ask, ask.id).state == "pending"

    Asks.run(["deny", short, "--note", "Use the cache.", "--by", "human:pat"], context())
    assert_receive {:mix_shell, :info, [json]}
    assert %{"state" => "denied"} = Jason.decode!(json)
    assert_receive {:permission_decision, _, :deny, "Use the cache."}
    assert %{decided_by: "human:pat"} = Repo.get(Ask, ask.id)

    assert_raise Refusal, ~r/already answered/, fn -> Asks.run(["allow", short], context()) end
    assert_raise Refusal, ~r/No such ask/, fn -> Asks.run(["allow", "nothere1"], context()) end
  end
end
