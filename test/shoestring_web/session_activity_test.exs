defmodule ShoestringWeb.SessionActivityTest do
  @moduledoc """
  The Sessions page's feed: worker rows from normalized events shaped as
  Codex and Claude record them, asks, Shoestring's steps, the row cap, and a
  coordinator's conversation.
  """
  use Shoestring.DataCase, async: false

  import Shoestring.SessionsFixtures

  alias Shoestring.{PermissionAsks, Repo}
  alias ShoestringWeb.SessionActivity

  setup do
    ctx = session()

    Map.put(
      ctx,
      :dispatch,
      dispatch_fixture(ctx, "implement", "builder", "Make add return the sum")
    )
  end

  defp rows(ctx, final? \\ false), do: SessionActivity.dispatch(ctx.dispatch, final?).rows
  defp of(rows, kind), do: Enum.filter(rows, &(&1.kind == kind))

  test "a Codex command's start and end are one row, with its exit code and time", ctx do
    goal = ctx.dispatch.goal_id

    worker_event(goal, "command", %{
      "codex-app-server:item_id" => "call_1",
      "codex-app-server:command" => "python3 -m pytest -q",
      "codex-app-server:cwd" => ctx.repo,
      "codex-app-server:status" => "inProgress"
    })

    assert [%{running: true, exit: nil}] = of(rows(ctx), :command)

    worker_event(goal, "command", %{
      "codex-app-server:item_id" => "call_1",
      "codex-app-server:command" => "python3 -m pytest -q",
      "codex-app-server:cwd" => ctx.repo,
      "codex-app-server:status" => "completed",
      "codex-app-server:exit_code" => 1,
      "codex-app-server:duration_ms" => 4100
    })

    assert [row] = of(rows(ctx), :command)

    assert {row.text, row.exit, row.seconds, row.running} ==
             {"python3 -m pytest -q", 1, 4.1, false}
  end

  test "a Codex file change shows its paths from the worktree with line counts", ctx do
    goal = ctx.dispatch.goal_id

    worker_event(goal, "command", %{
      "codex-app-server:item_id" => "call_1",
      "codex-app-server:command" => "ls",
      "codex-app-server:cwd" => ctx.repo
    })

    worker_event(goal, "tool", %{
      "codex-app-server:item_id" => "fc_1",
      "codex-app-server:tool" => "fileChange",
      "codex-app-server:status" => "inProgress"
    })

    worker_event(goal, "tool", %{
      "codex-app-server:item_id" => "fc_1",
      "codex-app-server:tool" => "fileChange",
      "codex-app-server:status" => "completed",
      "codex-app-server:changes" => [
        %{
          "path" => Path.join(ctx.repo, "calc.py"),
          "kind" => "update",
          "diff" => "--- a\n+++ b\n+x\n+y\n-z\n"
        }
      ]
    })

    assert [%{text: "calc.py +2 −1"}] = of(rows(ctx), :file)
  end

  test "streamed pieces of a Codex message become one row, replaced by the finished message",
       ctx do
    goal = ctx.dispatch.goal_id
    worker_event(goal, "output", %{"codex-app-server:delta" => "Two tests "})
    worker_event(goal, "output", %{"codex-app-server:delta" => "fail"})

    assert [%{text: "Two tests fail", writing: true}] = of(rows(ctx), :message)

    worker_event(goal, "output", %{
      "codex-app-server:text" => "Two tests fail, as expected.",
      "codex-app-server:phase" => "final_answer"
    })

    assert [%{text: "Two tests fail, as expected.", writing: false, final: true}] =
             of(rows(ctx), :message)
  end

  test "Claude: a Bash call is a command, an Edit is a file, and tool text is not a message",
       ctx do
    goal = ctx.dispatch.goal_id
    start = DateTime.utc_now()
    worker_event(goal, "lifecycle", %{"claude-headless:cwd" => ctx.repo}, start)

    worker_event(
      goal,
      "command",
      %{
        "claude-headless:boundary" => "start",
        "claude-headless:tool_use_id" => "toolu_1",
        "claude-headless:tool_name" => "Bash",
        "claude-headless:command" => "npm test"
      },
      DateTime.add(start, 1)
    )

    worker_event(
      goal,
      "command",
      %{
        "claude-headless:boundary" => "end",
        "claude-headless:tool_use_id" => "toolu_1",
        "claude-headless:is_error" => true
      },
      DateTime.add(start, 4)
    )

    worker_event(
      goal,
      "command",
      %{
        "claude-headless:boundary" => "start",
        "claude-headless:tool_use_id" => "toolu_2",
        "claude-headless:tool_name" => "Edit",
        "claude-headless:file_path" => Path.join(ctx.repo, "calc.py")
      },
      DateTime.add(start, 5)
    )

    worker_event(
      goal,
      "output",
      %{"claude-headless:output_text" => "Fixed it.", "claude-headless:role" => "assistant"},
      DateTime.add(start, 6)
    )

    worker_event(
      goal,
      "output",
      %{"claude-headless:output_text" => "tool output", "claude-headless:role" => "user"},
      DateTime.add(start, 7)
    )

    all = rows(ctx, true)
    assert [%{text: "npm test", failed: true, seconds: 3.0}] = of(all, :command)
    assert [%{text: "Edit calc.py"}] = of(all, :file)
    # The worker's last message is its final one once the dispatch is over.
    assert [%{text: "Fixed it.", final: true}] = of(all, :message)
    refute Enum.any?(all, &(&1.text == "tool output"))
  end

  test "secrets are redacted and the command around them is kept", ctx do
    worker_event(ctx.dispatch.goal_id, "command", %{
      "codex-app-server:item_id" => "call_1",
      "codex-app-server:command" =>
        "curl -H 'Authorization: Bearer abc.def.ghi' https://example.test/x"
    })

    [row] = of(rows(ctx), :command)
    assert row.text =~ "curl -H"
    assert row.text =~ "https://example.test/x"
    assert row.text =~ "[REDACTED]"
    refute row.text =~ "abc.def.ghi"
  end

  test "an event carrying only a reasoning field makes no row", ctx do
    worker_event(ctx.dispatch.goal_id, "output", %{
      "codex-app-server:reasoning_text" => "PRIVATE PLAN"
    })

    worker_event(ctx.dispatch.goal_id, "output", %{"codex-app-server:text" => "Visible."})

    all = rows(ctx)
    assert [%{text: "Visible."}] = of(all, :message)
    refute inspect(all) =~ "PRIVATE PLAN"
  end

  test "Shoestring's own steps are in the feed", ctx do
    assert [_ | _] = of(rows(ctx), :step)
  end

  test "an ask is a row, and its answer follows it", ctx do
    ask =
      Repo.insert!(%PermissionAsks.Ask{
        goal_id: ctx.dispatch.goal_id,
        run_id: Ecto.UUID.generate(),
        dispatch_id: ctx.dispatch.id,
        session_id: ctx.session,
        agent: "builder",
        provider: "codex",
        command: "npm ci",
        kind: "command"
      })

    assert [%{text: "Asked you to run outside its sandbox: npm ci", waiting: false}] =
             of(rows(ctx), :ask)

    Repo.update!(
      Ecto.Changeset.change(ask, state: "denied", note: "not now", decided_at: DateTime.utc_now())
    )

    assert Enum.any?(rows(ctx), &(&1.kind == :step and &1.text == "You denied it: not now"))
  end

  test "a long feed keeps its last rows and counts the rest", ctx do
    max = SessionActivity.max_rows()
    base = DateTime.utc_now()

    for n <- 1..(max + 10) do
      worker_event(
        ctx.dispatch.goal_id,
        "command",
        %{"codex-app-server:item_id" => "call_#{n}", "codex-app-server:command" => "echo #{n}"},
        DateTime.add(base, n)
      )
    end

    feed = SessionActivity.dispatch(ctx.dispatch)
    assert length(feed.rows) == max
    assert feed.omitted >= 10
    assert List.last(feed.rows).text == "echo #{max + 10}"
    refute Enum.any?(feed.rows, &(&1.text == "echo 1"))
  end

  test "a coordinator's feed: its turns, the tools it used, and both sides' messages", ctx do
    c = ctx.conversation
    t0 = DateTime.add(DateTime.utc_now(), 5)

    conversation_event(
      c,
      "conversation.message.human",
      %{"message_id" => "m1", "text" => "Fix add()"},
      t0
    )

    conversation_event(
      c,
      "conversation.turn.requested",
      %{"turn_id" => "t1", "message_ids" => ["m1"], "inbox_ids" => []},
      DateTime.add(t0, 1)
    )

    conversation_event(
      c,
      "conversation.tool.called",
      %{
        "turn_id" => "t1",
        "call_id" => "call-1",
        "tool" => "dispatch",
        "input" => %{"brief" => "SECRET BRIEF"}
      },
      DateTime.add(t0, 2)
    )

    conversation_event(
      c,
      "conversation.message.coordinator",
      %{"turn_id" => "t1", "item" => 0, "text" => "Dispatched it."},
      DateTime.add(t0, 3)
    )

    conversation_event(
      c,
      "conversation.turn.ended",
      %{"turn_id" => "t1", "status" => "completed", "usage" => %{}},
      DateTime.add(t0, 4)
    )

    rows = SessionActivity.coordinator([c]).rows
    texts = Enum.map(rows, &{&1.kind, &1.text})

    assert {:you, "Fix add()"} in texts
    assert {:step, "Turn 1 began: 1 message from you."} in texts
    assert {:tool, "dispatch"} in texts
    assert {:message, "Dispatched it."} in texts
    assert {:step, "Turn 1 ended."} in texts
    # Only the tool's name is shown, never its input.
    refute inspect(rows) =~ "SECRET BRIEF"
  end
end
