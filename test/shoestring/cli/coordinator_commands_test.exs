defmodule Shoestring.CLI.CoordinatorCommandsTest do
  @moduledoc """
  `shoestring grant`, `grants`, `dispatch`, `wait` and `runs` against a real
  temporary Git repository, Oban in manual testing mode, an injected terminal
  and session, and no service, provider or network. Scratch repositories are
  kept.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.{Dispatches, Grants, ModelCatalog, Repo}
  alias Shoestring.CLI.Commands.{Dispatch, Grant, Grants, Runs, Wait}
  alias Shoestring.CLI.Refusal
  alias Shoestring.Dispatches.Dispatch, as: DispatchRecord

  setup do
    repo = Path.join(System.tmp_dir!(), "shoestring-coordinator-#{Ecto.UUID.generate()}")
    File.mkdir_p!(Path.join(repo, "test"))
    File.write!(Path.join(repo, "calc.py"), "def add(a, b):\n    raise NotImplementedError\n")
    File.write!(Path.join(repo, "test/test_calc.py"), "import unittest\n")
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["add", "."])
    git!(repo, ["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qm", "base"])

    brief = Path.join(System.tmp_dir!(), "shoestring-brief-#{Ecto.UUID.generate()}.md")

    File.write!(
      brief,
      "IMPLEMENT - make add() return the sum\nContract: test/test_calc.py passes.\n"
    )

    {:ok, _} = ModelCatalog.add("codex", "gpt-6-luna")
    %{repo: repo, brief: brief}
  end

  defp git!(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  defp context(ctx, opts \\ []) do
    %{
      shell: Mix.Shell.Process,
      with_repo: fn fun -> fun.(Repo) end,
      cwd: ctx.repo,
      service: fn -> :ok end,
      start_hint: "mix phx.server",
      interactive?: fn -> Keyword.get(opts, :interactive, false) end,
      env: fn "SHOESTRING_SESSION" -> Keyword.get(opts, :session, "s1") end,
      poll_ms: 10,
      wait_ms: Keyword.get(opts, :wait_ms, 60_000)
    }
  end

  defp json! do
    assert_receive {:mix_shell, :info, [json]}
    Jason.decode!(json)
  end

  defp answer(text), do: send(self(), {:mix_shell_input, :prompt, text})

  defp grant!(ctx, extra \\ []) do
    answer("y")

    Grant.run(
      [
        "--models",
        "codex:gpt-6-luna",
        "--session",
        "s1",
        "--max-dispatches",
        "4",
        "--max-parallel",
        "2"
      ] ++
        extra,
      context(ctx, interactive: true)
    )

    json!()
  end

  defp dispatch_args(ctx, extra \\ []) do
    [
      "--purpose",
      "implement",
      "--worker",
      "codex:gpt-6-luna",
      "--title",
      "Make add return the sum"
    ] ++
      ["--brief", ctx.brief, "--file", "calc.py"] ++ extra
  end

  test "a grant needs a person at a terminal, shows itself and asks", ctx do
    assert_raise Refusal, ~r/A coordinator cannot grant itself/, fn ->
      Grant.run(["--models", "codex:gpt-6-luna"], context(ctx))
    end

    answer("n")

    assert_raise Refusal, "Not granted.", fn ->
      Grant.run(["--models", "codex:gpt-6-luna"], context(ctx, interactive: true))
    end

    assert Shoestring.Grants.list() == []

    grant = grant!(ctx)
    assert grant["session_id"] == "s1"
    assert grant["limits"]["max_dispatches"] == 4
    assert grant["purposes"] == ["explore", "implement", "review"]
    assert grant["room"]["attempts"] == %{"used" => 0, "limit" => 4}

    assert_received {:mix_shell, :error,
                     ["Granted. In the coordinator's shell: export SHOESTRING_SESSION=s1"]}

    answer("y")

    assert_raise Refusal, ~r/codex:unknown is not an enabled model/, fn ->
      Grant.run(["--models", "codex:unknown"], context(ctx, interactive: true))
    end
  end

  test "grants are listed and shown with their history; extend and revoke ask a person", ctx do
    %{"grant_id" => id} = grant!(ctx)

    assert_raise Refusal, ~r/A coordinator cannot grant itself/, fn ->
      Grants.run(["extend", id, "--dispatches", "2"], context(ctx))
    end

    answer("y")

    Grants.run(
      ["extend", id, "--dispatches", "2", "--hours", "1"],
      context(ctx, interactive: true)
    )

    assert %{"limits_revision" => 2, "limits" => %{"max_dispatches" => 6}} = json!()

    Grants.run(["show", id], context(ctx))
    assert %{"history" => [%{"kind" => "created"}, %{"kind" => "extended"}]} = json!()

    answer("y")
    Grants.run(["revoke", id], context(ctx, interactive: true))
    assert %{"revoked_by" => "human:" <> _} = json!()

    Grants.run(["list"], context(ctx))
    assert [%{"grant_id" => ^id}] = json!()
  end

  test "dispatch hands one task over under the grant and replays a retry", ctx do
    assert_raise Refusal, ~r/No grant for session s1/, fn ->
      Dispatch.run(dispatch_args(ctx), context(ctx))
    end

    grant!(ctx)

    Dispatch.run(dispatch_args(ctx, ["--dry-run"]), context(ctx))
    assert %{"would_dispatch" => true, "plan" => %{"tasks" => [_]}} = json!()
    assert Repo.all(DispatchRecord) == []

    Dispatch.run(dispatch_args(ctx), context(ctx))
    assert %{"outcome" => "recorded", "state" => "queued", "dispatch_id" => id} = first = json!()
    assert first["request_id"] =~ ~r/\Aauto-[0-9a-f]{24}\z/

    Dispatch.run(dispatch_args(ctx), context(ctx))
    assert %{"outcome" => "replayed", "dispatch_id" => ^id} = json!()

    assert_raise Refusal, ~r/Outside the grant: that model is not granted/, fn ->
      {:ok, _} = ModelCatalog.add("codex", "gpt-6.1-sol")
      Dispatch.run(dispatch_args(ctx, ["--worker", "codex:gpt-6.1-sol"]), context(ctx))
    end

    assert_raise Refusal, ~r/REVIEW dispatches are not available yet/, fn ->
      Dispatch.run(dispatch_args(ctx, ["--purpose", "review"]), context(ctx))
    end

    assert_raise Refusal, ~r/No coordinator session/, fn ->
      Dispatch.run(dispatch_args(ctx), %{context(ctx) | env: fn _ -> nil end})
    end

    assert_raise Refusal, ~r/not running/, fn ->
      Dispatch.run(dispatch_args(ctx), %{
        context(ctx)
        | service: fn -> {:error, :service_unreachable} end
      })
    end
  end

  test "wait returns on the first settled dispatch, or times out with exit 3", ctx do
    grant!(ctx)
    Dispatch.run(dispatch_args(ctx), context(ctx))
    %{"dispatch_id" => first} = json!()
    Dispatch.run(dispatch_args(ctx, ["--request-id", "second"]), context(ctx))
    %{"dispatch_id" => second} = json!()

    assert Wait.run([first, second], context(ctx, wait_ms: 50)) == 3

    assert %{
             "timed_out" => true,
             "dispatches" => [%{"state" => "queued"}, %{"state" => "queued"}]
           } = json!()

    # A dispatch that failed to start has settled.
    Dispatches.get(second) |> Ecto.Changeset.change(state: "failed", error: "x") |> Repo.update!()
    assert Wait.run([first, second], context(ctx)) == :ok

    assert %{
             "settled" => %{"dispatch_id" => ^second, "state" => "failed_to_start"},
             "others" => [%{"dispatch_id" => ^first}]
           } = json!()
  end

  test "advice prints a list, empty before any run finishes", ctx do
    Shoestring.CLI.Commands.Advice.run([], context(ctx))
    assert [] = json!()
  end

  test "runs lists the session's dispatches, shows one and cancels only its own", ctx do
    grant!(ctx)
    Dispatch.run(dispatch_args(ctx), context(ctx))
    %{"dispatch_id" => id} = json!()

    Runs.run(["list"], context(ctx))
    assert [%{"dispatch_id" => ^id, "worker" => "codex:gpt-6-luna"}] = json!()

    Runs.run(["list"], context(ctx, session: "someone-else"))
    assert [] = json!()

    Runs.run(["show", id], context(ctx))
    assert %{"state" => "queued", "result" => nil, "attempts_used" => _} = json!()

    assert_raise Refusal, ~r/belongs to another session/, fn ->
      Runs.run(["cancel", id, "--reason", "no"], context(ctx, session: "someone-else"))
    end

    Runs.run(["cancel", id, "--reason", "Superseded."], context(ctx))
    assert %{"dispatch_id" => ^id} = json!()
    assert_received {:mix_shell, :error, ["Cancellation requested for " <> _]}
  end
end
