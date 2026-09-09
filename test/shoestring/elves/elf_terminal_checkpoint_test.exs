defmodule Shoestring.Elves.ElfTerminalCheckpointTest do
  @moduledoc """
  Terminal-path recovery checkpoints with real repository evidence
  (Milestone 05, WP D loop-closure I3).

  Each test drives the real `Shoestring.Elves.Elf` terminal path with Fake
  scripted streams — never a provider CLI, never the network — and asserts a
  `checkpoint.created` event carrying durable evidence was appended BEFORE
  the terminal event.

  Locking note (standing contract): on the pre-fix base commit the Elf
  terminal path (`commit_terminal/2`) persists a log artifact + terminal
  event and stops without ever invoking the checkpoints writer, so every
  test asserting a terminal `checkpoint.created` fails behaviourally there.
  This file references only modules present on base, so those failures are
  behavioural (missing checkpoint events), never compile errors.
  """

  use Shoestring.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Shoestring.Elves
  alias Shoestring.Elves.Elf
  alias Shoestring.Harness.Fake.Scenario
  alias Shoestring.Repo
  alias Shoestring.Test.ElfWorktreeFixture
  alias Shoestring.Test.ElvesHelpers
  alias Shoestring.Trajectory.TrajectoryEvent

  @runner_opts [kill_grace_ms: 200, reap_timeout_ms: 2_000]
  @interval_ms 100

  setup do
    sup = start_supervised!({Shoestring.Elves.Supervisor, name: nil})
    %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()
    {:ok, sup: sup, goal: goal, task: task}
  end

  test "completed run checkpoint carries real diff/stat/changed files/exact test evidence/boundary",
       %{
         sup: sup,
         goal: goal,
         task: task
       } do
    run_id = Ecto.UUID.generate()
    fixture = ElfWorktreeFixture.create!(run_id)
    on_exit(fn -> ElfWorktreeFixture.cleanup!(fixture) end)

    request = ElvesHelpers.run_request(goal, task, workspace_ref: fixture.worktree.workspace_ref)

    # The child edits a tracked file (real diff stat) plus a new file
    # (changed-file list), guarded on the fixture marker, then exits fast so
    # the OS exit status is deterministically recorded before the verdict.
    child_script = """
    from pathlib import Path

    if Path("fixture.txt").exists():
        Path("fixture.txt").write_text("fixture baseline\\nterminal checkpoint edit\\n")
        Path("elf-terminal-checkpoint.txt").write_text("written by the Elf child\\n")
    """

    scenario =
      ElvesHelpers.custom_scenario(:terminal_completed, [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        command_event(source_event_id: "cmd-verify-1"),
        command_event(source_event_id: "cmd-verify-2"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               run_id: run_id,
               scenario: scenario,
               command: ["python3", "-c", child_script],
               runner_opts: @runner_opts,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    assert_receive {:elf_terminal, ^run_id, %{class: :completed}}, 10_000

    [checkpoint] = terminal_checkpoints(goal.id, run_id)
    terminal = ElvesHelpers.terminal_event(goal.id, run_id)

    assert terminal.type == "run.completed"
    assert checkpoint.sequence < terminal.sequence

    payload = checkpoint.payload
    assert payload["stop_reason"] == "run.completed"
    assert payload["extensions"]["shoestring.elf:checkpoint_kind"] == "terminal"

    assert payload["extensions"]["shoestring.elf:terminal_key"] ==
             "elf-terminal:#{request.dispatch_id}"

    assert payload["extensions"]["shoestring.elf:terminal_outcome"] == "completed"

    # Real repository evidence, not placeholders.
    assert payload["repository_state"]["revision"] == fixture.base_commit
    assert payload["repository_state"]["dirty"] == true

    evidence = Enum.join(payload["evidence"]["items"], "\n")
    assert evidence =~ fixture.base_commit
    assert evidence =~ "dirty true"
    assert evidence =~ "elf-terminal-checkpoint.txt"
    assert evidence =~ "fixture.txt"
    assert evidence =~ "diff stat"

    # Exact verification evidence from the run's trajectory events.
    assert evidence =~ "cmd-verify-1"
    assert evidence =~ "cmd-verify-2"
    assert evidence =~ "exit_status 0"

    # Last completed safe boundary + lease snapshot + outcome.
    assert evidence =~ "run.running"
    assert evidence =~ "lease: none"
    assert evidence =~ "outcome completed"

    assert payload["next_action"] =~ "completed"
    assert payload["next_action"] =~ "mix precommit"
  end

  test "failed run checkpoint carries failure plus rerun pointer", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    run_id = Ecto.UUID.generate()
    fixture = ElfWorktreeFixture.create!(run_id)
    on_exit(fn -> ElfWorktreeFixture.cleanup!(fixture) end)

    request = ElvesHelpers.run_request(goal, task, workspace_ref: fixture.worktree.workspace_ref)

    child_script = """
    from pathlib import Path

    if Path("fixture.txt").exists():
        Path("fixture.txt").write_text("fixture baseline\\nfailed run edit\\n")
    """

    crash =
      Shoestring.Harness.Error.new(
        :transport,
        "process_exited",
        "harness process terminated unexpectedly",
        retryable: false
      )

    scenario =
      ElvesHelpers.custom_scenario(
        :terminal_failed,
        [
          Scenario.lifecycle_event(source_event_id: "evt-life"),
          command_event(source_event_id: "cmd-work-1"),
          Scenario.error_event(crash, source_event_id: "evt-crash")
        ],
        provider_session_id: "fake-session-terminal-failed"
      )

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               run_id: run_id,
               scenario: scenario,
               command: ["python3", "-c", child_script],
               runner_opts: @runner_opts,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    assert_receive {:elf_terminal, ^run_id, %{class: :failed}}, 10_000

    [checkpoint] = terminal_checkpoints(goal.id, run_id)
    terminal = ElvesHelpers.terminal_event(goal.id, run_id)

    assert terminal.type == "run.failed"
    assert terminal.payload["error_code"] == "process_exited"
    assert checkpoint.sequence < terminal.sequence

    payload = checkpoint.payload
    assert payload["stop_reason"] == "run.failed:process_exited"
    assert payload["extensions"]["shoestring.elf:terminal_outcome"] == "failed"
    assert payload["provider_session_id"] == "fake-session-terminal-failed"

    evidence = Enum.join(payload["evidence"]["items"], "\n")
    assert evidence =~ "process_exited"
    assert evidence =~ "cmd-work-1"
    assert evidence =~ "dirty true"

    issues = payload["unresolved_issues"]["items"]
    assert Enum.any?(issues, &(&1 =~ "process_exited"))

    assert payload["next_action"] =~ "run.failed"
    assert payload["next_action"] =~ "elf-terminal:#{request.dispatch_id}"
    assert payload["next_action"] =~ "mix precommit"
  end

  test "failed-before-start run falls back to the template with no invented certainty", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    request = ElvesHelpers.run_request(goal, task)
    scenario = Scenario.start_failure()

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               notify: self()
             )

    assert_receive {:elf_terminal, run_id, %{class: :failed}}, 10_000

    [checkpoint] = terminal_checkpoints(goal.id, run_id)
    terminal = ElvesHelpers.terminal_event(goal.id, run_id)

    assert terminal.type == "run.failed"
    assert terminal.payload["error_code"] == "process_launch_failed"
    assert checkpoint.sequence < terminal.sequence

    payload = checkpoint.payload

    # The floor template: nothing is claimed about the worktree.
    assert payload["repository_state"]["revision"] == "unknown"
    assert payload["repository_state"]["dirty"] == false

    evidence = Enum.join(payload["evidence"]["items"], "\n")
    assert evidence =~ "no verification recorded"
    assert evidence =~ "process_launch_failed"
    assert evidence =~ "elf-terminal:#{request.dispatch_id}"

    assert payload["next_action"] =~ "run.failed"
    assert payload["next_action"] =~ "mix precommit"
  end

  test "checkpoint-writer failure still commits the terminal and records the error", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    Application.put_env(:shoestring, :terminal_checkpoint_writer, fn _goal_id,
                                                                     _checkpoint,
                                                                     _opts ->
      {:error, :checkpoint_writer_boom}
    end)

    on_exit(fn -> Application.delete_env(:shoestring, :terminal_checkpoint_writer) end)

    request = ElvesHelpers.run_request(goal, task)
    scenario = Scenario.normal_completion()

    log =
      capture_log(fn ->
        assert {:ok, _pid} =
                 Elves.start_run(request, ElvesHelpers.fake_identity(),
                   supervisor: sup,
                   scenario: scenario,
                   command: ["sleep", "30"],
                   runner_opts: @runner_opts,
                   notify: self()
                 )

        assert_receive {:elf_terminal, run_id, %{class: :completed}}, 10_000
        send(self(), {:terminal_seen, run_id})
      end)

    assert_received {:terminal_seen, run_id}

    # The terminal commit is never suppressed by the checkpoint failure.
    terminal = ElvesHelpers.terminal_event(goal.id, run_id)
    assert terminal.type == "run.completed"

    # Nothing durable was invented: no checkpoint was recorded ...
    assert terminal_checkpoints(goal.id, run_id) == []

    # ... and both failures (full inputs, then the floor retry) are surfaced.
    assert log =~ "elf terminal checkpoint failed"
    assert log =~ "checkpoint_writer_boom"
  end

  test "duplicate terminal path converges on a single checkpoint", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    request = ElvesHelpers.run_request(goal, task)
    scenario = ElvesHelpers.custom_scenario(:terminal_cancel, [Scenario.lifecycle_event()])

    assert {:ok, pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    assert {:ok, :cancelled} = Elf.cancel(pid)
    assert_receive {:elf_terminal, ^run_id, %{class: :cancelled}}, 10_000

    assert [%{payload: payload}] = terminal_checkpoints(goal.id, run_id)
    assert payload["stop_reason"] == "run.cancelled"
    assert payload["extensions"]["shoestring.elf:terminal_outcome"] == "cancelled"

    terminal = ElvesHelpers.terminal_event(goal.id, run_id)
    assert terminal.type == "run.cancelled"

    # The replay converges: the Elf is gone, the run is terminal, and no
    # second terminal or checkpoint is appended.
    assert {:ok, :already_terminal} = Elves.cancel_run(run_id)
    assert length(terminal_checkpoints(goal.id, run_id)) == 1
    assert ElvesHelpers.count_events(goal.id, run_id, ["run.cancelled"]) == 1
  end

  test "interrupted run checkpoints at the safe boundary", %{sup: sup, goal: goal, task: task} do
    request = ElvesHelpers.run_request(goal, task)

    scenario =
      ElvesHelpers.custom_scenario(:terminal_interrupted, [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        Scenario.output_event("boundary work", source_event_id: "evt-out"),
        Scenario.result_event("interrupted", source_event_id: "evt-interrupted")
      ])

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    assert_receive {:elf_terminal, run_id, %{class: :interrupted}}, 10_000

    [checkpoint] = terminal_checkpoints(goal.id, run_id)
    terminal = ElvesHelpers.terminal_event(goal.id, run_id)

    assert terminal.type == "run.interrupted"
    assert checkpoint.sequence < terminal.sequence
    assert checkpoint.payload["stop_reason"] == "run.interrupted"
    assert checkpoint.payload["extensions"]["shoestring.elf:terminal_outcome"] == "interrupted"
    assert checkpoint.payload["next_action"] =~ "interrupted"
  end

  # -- Helpers --

  defp terminal_checkpoints(goal_id, run_id) do
    Repo.all(
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^goal_id and event.run_id == ^run_id and
            event.type == "checkpoint.created",
        order_by: [asc: event.sequence]
    )
    |> Enum.filter(fn event ->
      event.payload["extensions"]["shoestring.elf:checkpoint_kind"] == "terminal"
    end)
  end

  defp command_event(opts) do
    %{
      kind: :command,
      offset_ms: Keyword.get(opts, :offset_ms, 0),
      source_event_id: Keyword.fetch!(opts, :source_event_id),
      error: nil,
      result: nil,
      capacity_snapshot: nil,
      extensions: %{"shoestring.fake:detail" => "verify"}
    }
  end

  defp wait_running(goal, dispatch_id) do
    assert {:ok, run_id} =
             ElvesHelpers.wait_until(fn -> ElvesHelpers.run_id_for_dispatch(dispatch_id) end)

    assert {:ok, _pgid} =
             ElvesHelpers.wait_until(fn -> ElvesHelpers.recorded_pgid(goal.id, run_id) end)

    run_id
  end
end
