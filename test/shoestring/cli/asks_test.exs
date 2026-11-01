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

  test "--for-agent allows and lets the agent run exactly that command again without asking" do
    {:ok, _} = Shoestring.ModelCatalog.add("codex", "gpt-6-luna")

    {:ok, _} =
      Shoestring.Agents.create(%{
        "name" => "Builder",
        "slug" => "builder",
        "kind" => "implementer",
        "provider" => "codex",
        "model" => "gpt-6-luna"
      })

    ask = waiting!("s1")
    Repo.update!(Ecto.Changeset.change(ask, rule_key: ask.command))
    short = String.slice(ask.id, 0, 8)

    Asks.run([], context())
    assert_receive {:mix_shell, :info, [text]}
    assert text =~ "shoestring asks allow #{short} --for-agent"

    assert_raise Refusal, ~r/goes with allow/, fn ->
      Asks.run(["deny", short, "--for-agent"], context())
    end

    Asks.run(["allow", short, "--for-agent"], context())
    assert_receive {:mix_shell, :info, [json]}
    assert %{"state" => "allowed"} = Jason.decode!(json)
    assert Shoestring.Agents.get_by_slug("builder").allowed_commands == [ask.command]

    # A file change or compound command is refused, and stays waiting.
    other = waiting!("s1")

    assert_raise Refusal, ~r/cannot be allowed for the agent/, fn ->
      Asks.run(["allow", String.slice(other.id, 0, 8), "--for-agent"], context())
    end

    assert PermissionAsks.waiting?(Repo.get(Ask, other.id))
  end

  test "a network ask says what allowing it does" do
    ask = waiting!("s1")

    Repo.update!(
      Ecto.Changeset.change(ask,
        kind: "network",
        provider: "claude",
        command: "Reach example.org from its commands"
      )
    )

    Asks.run([], context())
    assert_receive {:mix_shell, :info, [text]}
    assert text =~ "builder (claude) asks to reach a host not on its list:"
    assert text =~ "Reach example.org from its commands"
    assert text =~ "for the rest of this run"
    refute text =~ "$ Reach"
  end
end
