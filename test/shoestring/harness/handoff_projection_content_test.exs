defmodule Shoestring.Harness.HandoffProjectionContentTest do
  @moduledoc """
  What a handoff receiver is actually told (Milestone 05, WP D/F; the
  2026-09-24 live comparison, `production-unblock.md` §4.3 and §6.2).

  Standing-contract label: LOCK. Every test here except the one marked
  DOCUMENTATION fails on base `c1ae4a8` for the behavioural reason named in
  its comment, and references only modules present at base:

  - the composed prompt carried no objective, although the checkpoint records
    the goal/task acceptance contract (WP D: "goal, task, acceptance
    contract");
  - its Verification section was the first evidence items cut at 800
    characters — repository identity, diff stat, changed files — so the
    commands the sender ran never reached the receiver;
  - the checkpoint named each command by opaque id only, with no command
    text and no exit status (WP D: "commands/tests with exact exit status");
  - every checkpoint told the receiver to run `mix precommit`, whatever the
    repository was (the live Go receiver probed `ls mix.exs`).
  """

  use Shoestring.DataCase, async: false

  alias Shoestring.Elves.TerminalCheckpoint
  alias Shoestring.Harness.{Continuation, Security}
  alias Shoestring.Test.CobblerHelpers
  alias Shoestring.Test.ElfWorktreeFixture
  alias Shoestring.Test.FixedClock
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Trajectory

  @statement "Finish the CLI. Constraint: print no prompt text. " <>
               "Rejected approach: deleting legacy/ to silence go vet."

  defp continuation(cid), do: %{checkpoint_id: cid, next_action: "go on", decision_refs: []}

  defp identity_item do
    "repository 01950000-0000-7000-8000-000000000001 worktree " <>
      String.duplicate("w", 420) <>
      " branch shoestring/run-x base abc revision def dirty false"
  end

  describe "compose_handoff_prompt/2 with a checkpoint record" do
    # Base: no Objective section exists, so the statement is absent.
    test "carries the recorded acceptance contract once, as the Objective" do
      cid = Ecto.UUID.generate()

      record = %{
        id: cid,
        stop_reason: "run.completed",
        acceptance_contract: %{
          "criteria" => [
            "accept goal #{Ecto.UUID.generate()} \"Manual Run 1\" — #{@statement}",
            "accept task #{Ecto.UUID.generate()} \"Task for 1\" — #{@statement}"
          ]
        },
        decisions: %{"items" => []},
        unresolved_issues: %{"items" => []},
        evidence: %{"items" => ["verification: no verification recorded during the run"]},
        transcript: "SENDER-TRANSCRIPT-MARKER must never appear"
      }

      prompt = Continuation.compose_handoff_prompt(continuation(cid), checkpoint_record: record)

      assert prompt =~ "Objective: #{@statement}."
      # Goal and task share one statement: carried once, labels dropped.
      assert length(String.split(prompt, @statement)) == 2
      refute prompt =~ "Manual Run 1"
      # Both directions: required content present, transcript absent.
      refute prompt =~ "SENDER-TRANSCRIPT-MARKER"
      assert Security.scan_term(prompt) == []
      assert String.length(prompt) <= Continuation.handoff_prompt_max_chars()
    end

    # Base: the section was the first evidence items cut at 800 characters,
    # so with a realistic identity + diff stat ahead of the verification
    # block, the failing `go vet` never appears.
    test "Verification names the sender's finished commands with exit status, newest kept" do
      cid = Ecto.UUID.generate()

      commands =
        Enum.map(1..30, &"command item-#{&1} ordinal #{&1} exit 0: go test ./pkg#{&1}/...") ++
          ["command item-99 ordinal 99 exit 1: go vet ./..."]

      record = %{
        id: cid,
        stop_reason: "run.completed",
        decisions: %{"items" => []},
        unresolved_issues: %{"items" => []},
        evidence: %{
          "items" => [
            identity_item(),
            "diff stat: (part 1):\n" <> String.duplicate(" main.go | 3 +\n", 20),
            "changed files: (part 1):\nmain.go",
            "verification: os exit exit_status 0; (part 1):\n" <>
              Enum.join(Enum.take(commands, 16), "\n"),
            "verification: os exit exit_status 0; (part 2):\n" <>
              Enum.join(Enum.drop(commands, 16), "\n"),
            "last safe boundary: run.running evt-1"
          ]
        }
      }

      prompt = Continuation.compose_handoff_prompt(continuation(cid), checkpoint_record: record)
      [_, verification] = String.split(prompt, " Verification: ", parts: 2)

      assert verification =~ "exit 1: go vet ./..."
      assert verification =~ "exit 0: go test ./pkg30/..."
      assert verification =~ ~r/…\[\+\d+ earlier\]/
      refute verification =~ String.duplicate("w", 50)
      assert String.length(verification) <= Continuation.max_handoff_section_chars() + 1
    end

    # DOCUMENTATION (passes at base too): a record with no acceptance
    # contract and no finished commands composes the pre-existing sections.
    test "a record without contract or commands keeps the previous sections" do
      cid = Ecto.UUID.generate()

      record = %{
        id: cid,
        stop_reason: "run.failed:timeout",
        decisions: %{"items" => ["chose A"]},
        unresolved_issues: %{"items" => []},
        evidence: %{"items" => ["command cmd-1 ordinal 1"]}
      }

      prompt = Continuation.compose_handoff_prompt(continuation(cid), checkpoint_record: record)

      refute prompt =~ "Objective:"
      assert prompt =~ "Completed work: chose A."
      assert prompt =~ "Verification: command cmd-1 ordinal 1."
    end
  end

  describe "TerminalCheckpoint command evidence and next action" do
    # Base: evidence lines were `command <id> ordinal <n>` with no command
    # and no exit status, and next_action said `mix precommit`.
    test "a finished Codex command carries its command text and exit code" do
      %{state: state} = recorded_run!([codex_command(1, "/bin/zsh -lc 'go vet ./...'", 1)])

      assert {:ok, inputs} = TerminalCheckpoint.collect(state, %{class: :completed})
      evidence = Enum.join(inputs.evidence, "\n")

      assert evidence =~ "exit 1: /bin/zsh -lc 'go vet ./...'"
      refute inputs.next_action =~ "mix precommit"
      assert inputs.next_action =~ "rerunning the recorded verification commands"
    end

    # Base: the Claude END line named only its id; the command lived on the
    # START event, so the receiver could not tell what failed.
    test "a Claude tool end is joined to its start's command and reports failure" do
      %{state: state} =
        recorded_run!([
          claude_tool(1, "start", "toolu_01AAAAAAAAAAAAAAAAAAAAAA", command: "go test ./..."),
          claude_tool(2, "end", "toolu_01AAAAAAAAAAAAAAAAAAAAAA", is_error: true)
        ])

      assert {:ok, inputs} =
               TerminalCheckpoint.collect(state, %{
                 class: :failed,
                 error_category: "provider",
                 error_code: "x"
               })

      evidence = Enum.join(inputs.evidence, "\n")
      assert evidence =~ "failed: go test ./..."
      refute inputs.next_action =~ "mix precommit"
    end

    # Base: no command text was carried at all (fails on the first assert);
    # at head a 5 000-character command is cut to the bound with a marker.
    test "command text is bounded" do
      long = "echo " <> String.duplicate("a", 5_000)
      %{state: state} = recorded_run!([codex_command(1, long, 0)])

      assert {:ok, inputs} = TerminalCheckpoint.collect(state, %{class: :completed})
      evidence = Enum.join(inputs.evidence, "\n")

      assert evidence =~ "exit 0: echo aaa"
      assert evidence =~ "…[truncated]"
      refute evidence =~ String.duplicate("a", TerminalCheckpoint.max_command_chars())
    end

    # Base: every class's next_action named `mix precommit`.
    test "no terminal class prescribes an Elixir command" do
      %{state: state} = recorded_run!([])

      for terminal <- [
            %{class: :completed},
            %{class: :cancelled},
            %{class: :interrupted},
            %{class: :failed, error_category: "provider", error_code: "x"}
          ] do
        assert {:ok, inputs} = TerminalCheckpoint.collect(state, terminal)
        refute inputs.next_action =~ "mix", inspect(terminal)
      end
    end
  end

  defp recorded_run!(events) do
    goal = FakeHelpers.insert_goal()
    task = FakeHelpers.insert_task(goal)
    dispatch_id = Ecto.UUID.generate()
    run = FakeHelpers.insert_run_record(goal, task, dispatch_id)
    fixture = ElfWorktreeFixture.create!(run.id)
    on_exit(fn -> ElfWorktreeFixture.cleanup!(fixture) end)

    for {ordinal, kind, extensions} <- events do
      assert {:ok, _event} =
               Trajectory.append(
                 goal.id,
                 %{
                   "type" => "harness.event_recorded",
                   "schema_version" => 1,
                   "actor" => "elf",
                   "occurred_at" => CobblerHelpers.now(),
                   "idempotency_key" => "rec:#{run.id}:#{ordinal}",
                   "payload" => %{
                     "run_id" => run.id,
                     "source_event_id" => "item-#{ordinal}",
                     "ordinal" => ordinal,
                     "occurred_at" => DateTime.to_iso8601(CobblerHelpers.now()),
                     "kind" => kind,
                     "extensions" => extensions
                   }
                 },
                 trusted: [task_id: task.id, run_id: run.id]
               )
    end

    state = %{
      goal_id: goal.id,
      run_id: run.id,
      dispatch_id: dispatch_id,
      request: %{workspace_ref: fixture.worktree.workspace_ref},
      provider_session_id: nil,
      lease_bounds: nil,
      lease_grant_id: nil,
      lease_deadline: nil,
      lease_checkpoint_id: nil,
      lease_checkpointed?: false,
      os_exit: {:exit_status, 0},
      repo: Shoestring.Repo,
      clock: FixedClock
    }

    %{state: state, goal: goal, run: run}
  end

  defp codex_command(ordinal, command, exit_code) do
    {ordinal, "command",
     %{
       "codex-app-server:command" => command,
       "codex-app-server:status" => if(exit_code == 0, do: "completed", else: "failed"),
       "codex-app-server:exit_code" => exit_code
     }}
  end

  defp claude_tool(ordinal, boundary, tool_use_id, opts) do
    base = %{
      "claude-headless:boundary" => boundary,
      "claude-headless:tool_name" => "Bash",
      "claude-headless:tool_use_id" => tool_use_id
    }

    extensions =
      case boundary do
        "start" ->
          Map.put(base, "claude-headless:command", Keyword.fetch!(opts, :command))

        "end" ->
          Map.merge(base, %{
            "claude-headless:is_error" => Keyword.get(opts, :is_error, false),
            "claude-headless:status" =>
              if(Keyword.get(opts, :is_error, false), do: "failed", else: "completed")
          })
      end

    {ordinal, "command", extensions}
  end
end
