defmodule Shoestring.CLI.ExternalTest do
  @moduledoc """
  Iteration 20 surfaces: `shoestring external`, `shoestring dispatch
  --purpose external`, `shoestring grant --units`, `runs show`, the
  coordinator's dispatch tool, and attention. Hermetic.
  """
  use Shoestring.DataCase, async: false

  import Shoestring.Test.ExternalHelpers

  alias Shoestring.{Attention, Dispatches}
  alias Shoestring.CLI.Commands.{External, Runs}
  alias Shoestring.CLI.Refusal
  alias Shoestring.Coordinator.Tools
  alias Shoestring.Dispatches.Externals

  @moduletag :tmp_dir

  setup %{tmp_dir: dir}, do: external_session(dir)

  defp context(ctx, opts \\ []) do
    %{
      shell: Mix.Shell.Process,
      with_repo: fn fun -> fun.(Repo) end,
      cwd: ctx.repo,
      interactive?: fn -> Keyword.get(opts, :interactive, true) end,
      env: fn "SHOESTRING_SESSION" -> ctx.session end,
      service: fn -> :ok end,
      oban: Oban,
      external_opts: Keyword.get(opts, :external_opts, worktrees_dir: ctx.worktrees)
    }
  end

  defp drain do
    receive do
      {:mix_shell, _, _} -> drain()
    after
      0 -> :ok
    end
  end

  defp json do
    receive do
      {:mix_shell, :info, [text]} ->
        case Jason.decode(text) do
          {:ok, data} -> data
          _ -> json()
        end
    after
      1_000 -> flunk("no JSON output")
    end
  end

  test "start, confirm, complete and abandon from a terminal; an agent cannot", ctx do
    brief = Path.join(ctx.repo, "../brief.md")
    File.write!(brief, "EXTERNAL - draw it\nContract: tests/test_tool.py passes.\n")

    External.run(
      [
        "start",
        "--title",
        "Draw it",
        "--brief",
        brief,
        "--units",
        "flow_credits=30",
        "--test",
        "tests/test_tool.py"
      ],
      context(ctx)
    )

    %{"dispatch_id" => id} = json()
    drain()
    short = String.slice(id, 0, 8)
    dispatch = Dispatches.get(id)
    assert Dispatches.state(dispatch) == "held"
    assert Externals.get(id).units_reserved == %{"flow_credits" => 30}

    assert_raise Refusal, ~r/person's step/, fn ->
      External.run(["confirm", short], context(ctx, interactive: false))
    end

    External.run(["confirm", short], context(ctx))
    %{"state" => "awaiting", "worktree" => path} = json()
    drain()

    assert_raise Refusal, ~r/person's step/, fn ->
      External.run(["complete", short], context(ctx, interactive: false))
    end

    commit_in!(path)

    External.run(
      ["complete", short, "--units", "flow_credits=12"],
      context(ctx, external_opts: passing())
    )

    assert_receive {:mix_shell, :error, ["Completed: its checks passed at " <> _]}
    drain()
    assert Externals.get(id).units_actual == %{"flow_credits" => 12}

    assert_raise Refusal, ~r/already completed/, fn ->
      External.run(["abandon", short, "--reason", "late"], context(ctx))
    end

    External.run(["show", short], context(ctx))
    assert_receive {:mix_shell, :info, [text]}
    assert text =~ "State: completed"
    assert text =~ "outside Shoestring's guarantee"
  end

  test "dispatch --purpose external needs no worker and refuses one", ctx do
    {:ok, request} =
      Shoestring.CLI.Commands.Dispatch.build_request(%{
        session_id: ctx.session,
        purpose: "external",
        title: "T",
        brief: "B",
        repository: ctx.repo,
        units: ["flow_credits=5"]
      })

    assert {request.provider, request.model} == Dispatches.external_worker()

    assert {:error, "An EXTERNAL has no worker" <> _} =
             Shoestring.CLI.Commands.Dispatch.build_request(%{
               session_id: ctx.session,
               purpose: "external",
               worker: "codex:gpt-6-luna",
               title: "T",
               brief: "B",
               repository: ctx.repo
             })
  end

  test "runs show tells the coordinator the person's next step for each state", ctx do
    dispatch = started!(ctx)
    held = Runs.detail(dispatch)
    assert held["state"] == "held"
    assert held["next"] =~ "waits for the person to start it"
    assert held["next"] =~ "You cannot start it."

    assert :confirmed = Externals.confirm(dispatch, by(), worktrees_dir: ctx.worktrees)
    awaiting = Runs.detail(dispatch)
    assert awaiting["external"]["worktree"] =~ "worktrees"
    assert awaiting["next"] =~ "shoestring external complete"
    assert awaiting["next"] =~ "You cannot complete it."

    {:ok, _} = Externals.complete(dispatch, by(), %{}, passing())
    needs = Runs.detail(dispatch)
    assert needs["state"] == "needs_you"
    assert needs["next"] =~ "nothing was committed"
  end

  test "the coordinator may dispatch EXTERNAL without a worker, held, and cannot finish it",
       ctx do
    binding = %{session_id: ctx.session, repository: ctx.repo}

    assert {:ok, %{"dispatch_id" => id}} =
             Tools.call(
               "dispatch",
               %{
                 "purpose" => "external",
                 "title" => "Generate the sheet in the web app",
                 "brief" => "EXTERNAL - one sheet\nContract: tests/test_tool.py passes.\n",
                 "tests" => ["tests/test_tool.py"],
                 "units" => ["flow_credits=20"]
               },
               binding
             )

    dispatch = Dispatches.get(id)
    assert Dispatches.state(dispatch) == "held"

    # Its cancel is the grant's, never the person's abandonment.
    assert {:error, _} =
             Tools.call("runs_cancel", %{"dispatch" => id, "reason" => "stop"}, binding)

    assert Externals.get(id).state == "held"
  end

  test "attention: start the held one, then its item shows where to work and the commands", ctx do
    dispatch = started!(ctx)

    assert [%{kind: :held, title: "Start this EXTERNAL work?"} = held] =
             Attention.items(ctx.session)

    assert held.note =~ "outside Shoestring's guarantee"
    before = Attention.count()

    assert :confirmed = Attention.start_held(ctx.session, dispatch.id, by())

    assert [%{kind: :external} = item] = Attention.items(ctx.session)
    assert item.title == "EXTERNAL work waits for you"
    assert Enum.any?(item.lines, &String.starts_with?(&1, "Worktree: "))
    assert Enum.any?(item.commands, &(&1 =~ "shoestring external complete"))
    assert Attention.count() == before

    {:ok, _} = Externals.complete(dispatch, by(), %{}, passing())

    assert [%{kind: :external, title: "This EXTERNAL's result was not accepted"} = failed] =
             Attention.items(ctx.session)

    assert failed.why =~ "nothing was committed"
  end
end
