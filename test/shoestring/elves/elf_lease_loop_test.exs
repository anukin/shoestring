defmodule Shoestring.Elves.ElfLeaseLoopTest do
  @moduledoc """
  Hermetic Elf-loop lease accounting tests (Milestone 05, WP C loop-closure I2).

  Each test drives the real `Shoestring.Elves.Elf` ingest path with Fake
  scripted streams and a FixedClock — never a provider CLI, never the
  network. A lease is granted for the Elf's own run mid-stream (budgets,
  reserves, cadence, deadline chosen per test); the loop must advance spend
  from normalized events only, mark `lease.renewal_due` at the configured
  boundary or deadline, run the T2 renewal sequence at item.completed, and
  enter the reactive checkpoint path on in-flight exhaustion — without ever
  interrupting a mutation mid-item.

  Locking note (standing contract): on the pre-fix commit
  (`LeaseBounds.advance/2` has zero lib callers) the Elf never appends
  `lease.renewal_due` / `lease.renewed` / `lease.expired` /
  `lease.checkpoint_required` / `checkpoint.created` during a run, so every
  test asserting those appends fails behaviourally there and locks the loop.
  The no-lease and lifecycle-noise tests assert the absence of lease effects
  and therefore also pass on base — they are documentation, labeled as such.
  """

  use Shoestring.DataCase, async: false

  import Ecto.Query

  alias Shoestring.Cobbler.{GoalLocalObservation, Leases}
  alias Shoestring.Cobbler.WakeupRecord
  alias Shoestring.Elves

  alias Shoestring.Harness.{
    CapacitySnapshot,
    ExecutionLease,
    ExecutionLeaseRecord,
    Projector,
    RunRecord
  }

  alias Shoestring.Harness.Fake.Scenario
  alias Shoestring.Repo
  alias Shoestring.Test.CobblerHelpers
  alias Shoestring.Test.ElvesHelpers
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Test.FixedClock
  alias Shoestring.Trajectory.TrajectoryEvent

  @runner_opts [kill_grace_ms: 200, reap_timeout_ms: 2_000]
  @interval_ms 200

  setup do
    sup = start_supervised!({Shoestring.Elves.Supervisor, name: nil})
    %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()
    {:ok, sup: sup, goal: goal, task: task}
  end

  test "response spend is exact and due fires one reserve early, then renews", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    # response_budget 4, reserve 1 → due at the 3rd output completion.
    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    scenario =
      fake_scenario(:response_spend, healthy_snapshot(fresh_id), [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        Scenario.output_event("one", source_event_id: "evt-out-1"),
        Scenario.output_event("two", source_event_id: "evt-out-2"),
        Scenario.output_event("three", source_event_id: "evt-out-3"),
        Scenario.output_event("four", source_event_id: "evt-out-4"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    hold_before_first_event(pid)
    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    grant_for_run!(goal, run_id, fresh_id,
      response_budget: 4,
      tool_budget: 25,
      reserves: %{response: 1, tool: 1},
      checkpoint_cadence: 100,
      deadline: DateTime.add(FixedClock.now(), 3_600, :second)
    )

    release_elf(pid)

    assert_receive {:elf_terminal, ^run_id, %{class: :completed}}, 15_000

    assert count_types(goal.id, run_id, ["lease.renewal_due"]) == 1
    assert count_types(goal.id, run_id, ["lease.renewed"]) == 1
    assert reactive_checkpoint_count(goal.id, run_id) == 0
    # I3 terminal checkpoint: every terminal appends exactly one repo-evidence
    # checkpoint before the terminal event, even when the loop wrote none.
    assert terminal_checkpoint_count(goal.id, run_id) == 1

    ordered = ordered_events(goal.id, run_id)
    assert sequence_before?(ordered, {:harness, "evt-out-3"}, {"lease.renewal_due", nil})
    assert sequence_before?(ordered, {"lease.renewal_due", nil}, {:harness, "evt-out-4"})
    assert sequence_before?(ordered, {"lease.renewal_due", nil}, {"lease.renewed", nil})

    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)
    record = Repo.get_by!(ExecutionLeaseRecord, run_id: run_id)
    assert record.status == "renewed"

    assert record.admitted_snapshot_id ==
             GoalLocalObservation.snapshot_id("lease-renewal", goal.id, record.id, fresh_id)
  end

  test "tool and command completions spend exactly once; START frames never spend", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    # tool_budget 3, reserve 1 → due at the 2nd tool spend. The command
    # START spends nothing; its END spends one; the :tool spends the second.
    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    scenario =
      fake_scenario(:tool_spend, healthy_snapshot(fresh_id), [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        command_event("cmd-1", "inProgress", source_event_id: "evt-cmd-start"),
        command_event("cmd-1", "completed", source_event_id: "evt-cmd-end"),
        tool_event(source_event_id: "evt-tool-1"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    hold_before_first_event(pid)
    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    grant_for_run!(goal, run_id, fresh_id,
      response_budget: 100,
      tool_budget: 3,
      reserves: %{response: 1, tool: 1},
      checkpoint_cadence: 100,
      deadline: DateTime.add(FixedClock.now(), 3_600, :second)
    )

    release_elf(pid)

    assert_receive {:elf_terminal, ^run_id, %{class: :completed}}, 15_000

    # Due fired exactly once — at the 2nd tool spend (the :tool event), not
    # at the START (zero spend) nor at the END (first spend).
    assert count_types(goal.id, run_id, ["lease.renewal_due"]) == 1

    ordered = ordered_events(goal.id, run_id)
    assert sequence_before?(ordered, {:harness, "evt-cmd-end"}, {"lease.renewal_due", nil})
    assert sequence_before?(ordered, {:harness, "evt-tool-1"}, {"lease.renewal_due", nil})
    assert sequence_before?(ordered, {"lease.renewal_due", nil}, {:harness, "evt-done"})
  end

  test "delta frames never spend: due waits for real completions", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    # response_budget 3, reserve 1 → due at the 2nd real completion. Two
    # delta frames interleaved must not move the counter.
    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    scenario =
      fake_scenario(:delta_noise, healthy_snapshot(fresh_id), [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        delta_event(source_event_id: "evt-delta-1"),
        Scenario.output_event("one", source_event_id: "evt-out-1"),
        delta_event(source_event_id: "evt-delta-2"),
        Scenario.output_event("two", source_event_id: "evt-out-2"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    hold_before_first_event(pid)
    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    grant_for_run!(goal, run_id, fresh_id,
      response_budget: 3,
      tool_budget: 25,
      reserves: %{response: 1, tool: 1},
      checkpoint_cadence: 100,
      deadline: DateTime.add(FixedClock.now(), 3_600, :second)
    )

    release_elf(pid)

    assert_receive {:elf_terminal, ^run_id, %{class: :completed}}, 15_000

    assert count_types(goal.id, run_id, ["lease.renewal_due"]) == 1

    ordered = ordered_events(goal.id, run_id)
    assert sequence_before?(ordered, {:harness, "evt-out-2"}, {"lease.renewal_due", nil})
    assert sequence_before?(ordered, {"lease.renewal_due", nil}, {:harness, "evt-done"})
  end

  test "deadline path marks due then renews against the fresh snapshot", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    # The deadline is already past with no spend at all: the due marker
    # lands on the first ingested event, and the renewal itself waits for
    # the authoritative turn outcome (terminal-only: nothing mid-turn may
    # suspend or interrupt, and a renewal needs no earlier trigger).
    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    scenario =
      fake_scenario(:deadline_renew, healthy_snapshot(fresh_id), [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    hold_before_first_event(pid)
    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    grant_for_run!(goal, run_id, fresh_id,
      response_budget: 100,
      tool_budget: 100,
      reserves: %{response: 1, tool: 1},
      checkpoint_cadence: 100,
      deadline: DateTime.add(FixedClock.now(), -60, :second)
    )

    release_elf(pid)

    assert_receive {:elf_terminal, ^run_id, %{class: :completed}}, 15_000

    assert count_types(goal.id, run_id, ["lease.renewal_due"]) == 1
    assert count_types(goal.id, run_id, ["lease.renewed"]) == 1

    ordered = ordered_events(goal.id, run_id)

    # The deadline had already passed, so due is marked on the first
    # ingested event (even the lifecycle handshake); the renewal lands
    # after the result is durable.
    assert sequence_before?(ordered, {:harness, "evt-life"}, {"lease.renewal_due", nil})
    assert sequence_before?(ordered, {:harness, "evt-done"}, {"lease.renewed", nil})
    assert sequence_before?(ordered, {"lease.renewal_due", nil}, {"lease.renewed", nil})

    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    record = Repo.get_by!(ExecutionLeaseRecord, run_id: run_id)
    assert record.status == "renewed"

    assert record.admitted_snapshot_id ==
             GoalLocalObservation.snapshot_id("lease-renewal", goal.id, record.id, fresh_id)
  end

  test "refused renewal expires then checkpoints at the outcome without interrupting the item",
       %{sup: sup, goal: goal, task: task} do
    # Breached fresh capacity: mid-turn spends only record the expiry
    # (durable marker, no suspend); the turn outcome completes the decline
    # with checkpoint contents — while every item still flows to its own
    # outcome (no mid-item interrupt, no premature suspension).
    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id, used_percent: 95.0)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    scenario =
      fake_scenario(:deadline_expire, breached_snapshot(fresh_id), [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        Scenario.output_event("first", source_event_id: "evt-out-1"),
        Scenario.output_event("second", source_event_id: "evt-out-2"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    hold_before_first_event(pid)
    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    grant_for_run!(goal, run_id, fresh_id,
      response_budget: 100,
      tool_budget: 100,
      reserves: %{response: 1, tool: 1},
      checkpoint_cadence: 100,
      deadline: DateTime.add(FixedClock.now(), -60, :second)
    )

    release_elf(pid)

    # The outcome consumed the decline: markers land, no terminal follows.
    wait_decline_wake(goal.id, run_id)

    assert count_types(goal.id, run_id, ["lease.expired"]) == 1
    assert count_types(goal.id, run_id, ["lease.checkpoint_required"]) == 1
    assert reactive_checkpoint_count(goal.id, run_id) == 1
    assert count_types(goal.id, run_id, ["run.suspended"]) == 1

    ordered = ordered_events(goal.id, run_id)

    assert sequence_before?(ordered, {"lease.expired", nil}, {"lease.checkpoint_required", nil})

    # The reactive checkpoint lands at the turn outcome: the result is
    # durable first, and no terminal verdict follows a suspended run.
    assert sequence_before?(ordered, {:harness, "evt-done"}, {"checkpoint.created", nil})
    assert sequence_before?(ordered, {:harness, "evt-done"}, {"run.suspended", nil})
    assert no_terminal_event?(goal.id, run_id)
    refute_receive {:elf_terminal, ^run_id, _}

    # Nothing was interrupted mid-item: both outputs and the verdict landed.
    assert count_types(goal.id, run_id, ["harness.event_recorded"]) == 4

    # Terminal-only (B1/B3a): the outcome decline suspends instead of
    # terminalizing. The run row projects as suspended (not completed),
    # and the lease row keeps the checkpoint_required status the mid-turn
    # expiry recorded.
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)
    assert Repo.get_by!(RunRecord, id: run_id).status == "suspended"
    assert Repo.get_by!(ExecutionLeaseRecord, run_id: run_id).status == "checkpoint_required"
  end

  test "in-flight exhaustion checkpoints at the outcome; the turn still completes", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    # response_budget 2, zero reserve: the 2nd output exhausts the allowance
    # in-flight. Nothing suspends mid-turn; the outcome completes the
    # decline with checkpoint contents while every item still flows to its
    # own outcome (no mid-item interrupt, no premature suspension).
    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id, used_percent: 95.0)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    scenario =
      fake_scenario(:exhausted, breached_snapshot(fresh_id), [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        Scenario.output_event("one", source_event_id: "evt-out-1"),
        Scenario.output_event("two", source_event_id: "evt-out-2"),
        Scenario.output_event("three", source_event_id: "evt-out-3"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    hold_before_first_event(pid)
    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    grant_for_run!(goal, run_id, fresh_id,
      response_budget: 2,
      tool_budget: 25,
      reserves: %{response: 0, tool: 0},
      checkpoint_cadence: 100,
      deadline: DateTime.add(FixedClock.now(), 3_600, :second)
    )

    release_elf(pid)

    # The outcome consumed the decline: markers land, no terminal follows.
    wait_decline_wake(goal.id, run_id)

    assert count_types(goal.id, run_id, ["lease.expired"]) == 1
    assert reactive_checkpoint_count(goal.id, run_id) == 1
    assert count_types(goal.id, run_id, ["run.suspended"]) == 1
    assert terminal_checkpoint_count(goal.id, run_id) == 0

    ordered = ordered_events(goal.id, run_id)

    # Exhaustion hit exactly at the 2nd output but nothing suspended
    # mid-turn: the checkpoint follows the turn outcome, and no terminal
    # verdict follows a suspended run.
    assert sequence_before?(ordered, {:harness, "evt-done"}, {"checkpoint.created", nil})
    assert sequence_before?(ordered, {:harness, "evt-done"}, {"run.suspended", nil})
    assert no_terminal_event?(goal.id, run_id)
    refute_receive {:elf_terminal, ^run_id, _}
    assert count_types(goal.id, run_id, ["harness.event_recorded"]) == 5
  end

  # LOCK (fails behaviourally on 1566acd and on e675c3b): the live shape
  # of final-acceptance.md §5.2. The deadline has passed, and the next
  # event is the START of a Codex `fileChange`. Past designs declined at
  # the START (spend counting), at the END, or after model activity —
  # each before the turn provably stopped. Terminal-only declines at the
  # turn outcome: nothing suspends while the write may still be running.
  test "a passed deadline with a file change suspends only at the turn outcome", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id, used_percent: 95.0)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    scenario =
      fake_scenario(:deadline_expire, breached_snapshot(fresh_id), [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        codex_file_change("fc-1", "inProgress", source_event_id: "item-started-fc-1"),
        codex_file_change("fc-1", "completed", source_event_id: "item-completed-fc-1"),
        delta_event(source_event_id: "evt-delta-after"),
        Scenario.output_event("after", source_event_id: "evt-out-after"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    hold_before_first_event(pid)
    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    grant_for_run!(goal, run_id, fresh_id,
      response_budget: 100,
      tool_budget: 100,
      reserves: %{response: 1, tool: 1},
      checkpoint_cadence: 100,
      deadline: DateTime.add(FixedClock.now(), -60, :second)
    )

    release_elf(pid)

    # The outcome consumed the decline: markers land, no terminal follows.
    wait_decline_wake(goal.id, run_id)

    assert count_types(goal.id, run_id, ["lease.expired"]) == 1
    assert reactive_checkpoint_count(goal.id, run_id) == 1
    assert count_types(goal.id, run_id, ["run.suspended"]) == 1

    ordered = ordered_events(goal.id, run_id)

    # Nothing suspended before the turn outcome proved it stopped: expiry,
    # checkpoint, and suspension all follow the result.
    assert sequence_before?(ordered, {:harness, "evt-done"}, {"lease.expired", nil})

    assert sequence_before?(
             ordered,
             {:harness, "evt-done"},
             {"checkpoint.created", nil}
           )

    assert sequence_before?(ordered, {:harness, "evt-done"}, {"run.suspended", nil})
    assert no_terminal_event?(goal.id, run_id)
    refute_receive {:elf_terminal, ^run_id, _}
  end

  # LOCK (fails behaviourally on 1566acd and on e675c3b): past the
  # deadline, spends beside an open command must not decline — and neither
  # may the tool END alone. Terminal-only declines at the turn outcome, so
  # no suspension precedes the proof the turn stopped. On 1566acd the Elf
  # declines at the message; on e675c3b it declines at the END.
  test "a passed deadline with a message while a command is open suspends only at the outcome",
       %{sup: sup, goal: goal, task: task} do
    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id, used_percent: 95.0)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    scenario =
      fake_scenario(:deadline_expire, breached_snapshot(fresh_id), [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        codex_command_start("cmd-1", source_event_id: "item-started-cmd-1"),
        Scenario.output_event("mid", source_event_id: "evt-out-mid"),
        command_event("cmd-1", "completed", source_event_id: "item-completed-cmd-1"),
        delta_event(source_event_id: "evt-delta-after"),
        Scenario.output_event("after", source_event_id: "evt-out-after"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    hold_before_first_event(pid)
    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    grant_for_run!(goal, run_id, fresh_id,
      response_budget: 100,
      tool_budget: 100,
      reserves: %{response: 1, tool: 1},
      checkpoint_cadence: 100,
      deadline: DateTime.add(FixedClock.now(), -60, :second)
    )

    release_elf(pid)

    # The outcome consumed the decline: markers land, no terminal follows.
    wait_decline_wake(goal.id, run_id)

    assert count_types(goal.id, run_id, ["lease.expired"]) == 1
    assert reactive_checkpoint_count(goal.id, run_id) == 1
    assert count_types(goal.id, run_id, ["run.suspended"]) == 1

    ordered = ordered_events(goal.id, run_id)

    assert sequence_before?(ordered, {:harness, "evt-done"}, {"lease.expired", nil})

    assert sequence_before?(
             ordered,
             {:harness, "evt-done"},
             {"checkpoint.created", nil}
           )

    assert sequence_before?(ordered, {:harness, "evt-done"}, {"run.suspended", nil})
    assert no_terminal_event?(goal.id, run_id)
    refute_receive {:elf_terminal, ^run_id, _}
  end

  # LOCK (fails behaviourally on 1566acd and on e675c3b): the Claude twin
  # of the message-while-open rule with real Claude shapes only (tool
  # start/end by `tool_use_id`, text completions, result — no deltas, which
  # the Claude normalizer never emits). Spends beside the open tool must
  # not decline, and neither may the tool END alone: terminal-only declines
  # at the turn outcome. On 1566acd the Elf declines at the message; on
  # e675c3b it declines at the END.
  test "a passed deadline with a message while a Claude tool is open suspends only at the outcome",
       %{sup: sup, goal: goal, task: task} do
    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id, used_percent: 95.0)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    scenario =
      fake_scenario(:deadline_expire, breached_snapshot(fresh_id), [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        claude_tool_start("toolu_7", source_event_id: "evt-claude-start"),
        Scenario.output_event("mid", source_event_id: "evt-out-mid"),
        claude_tool_end("toolu_7", source_event_id: "evt-claude-end"),
        Scenario.output_event("after", source_event_id: "evt-out-after"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    hold_before_first_event(pid)
    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    grant_for_run!(goal, run_id, fresh_id,
      response_budget: 100,
      tool_budget: 100,
      reserves: %{response: 1, tool: 1},
      checkpoint_cadence: 100,
      deadline: DateTime.add(FixedClock.now(), -60, :second)
    )

    release_elf(pid)

    # The outcome consumed the decline: markers land, no terminal follows.
    wait_decline_wake(goal.id, run_id)

    assert count_types(goal.id, run_id, ["lease.expired"]) == 1
    assert reactive_checkpoint_count(goal.id, run_id) == 1
    assert count_types(goal.id, run_id, ["run.suspended"]) == 1

    ordered = ordered_events(goal.id, run_id)

    assert sequence_before?(ordered, {:harness, "evt-done"}, {"lease.expired", nil})

    assert sequence_before?(
             ordered,
             {:harness, "evt-done"},
             {"checkpoint.created", nil}
           )

    assert sequence_before?(ordered, {:harness, "evt-done"}, {"run.suspended", nil})
    assert no_terminal_event?(goal.id, run_id)
    refute_receive {:elf_terminal, ^run_id, _}
  end

  # LOCK vs e675c3b (fails there behaviourally; passes on 1566acd, so
  # documentation against the original base): the Claude budget-due twin
  # with real Claude shapes only (no deltas). e675c3b's control gate
  # (completions after tools never re-arm) made Claude renewal unreachable
  # — no delta ever arrives to establish control — while terminal-only
  # keeps the mid-turn budget renewal working: a healthy budget exhaustion
  # renews, and the terminal proceeds normally with exactly one renewal.
  test "a budget-due Claude turn renews once and completes normally",
       %{sup: sup, goal: goal, task: task} do
    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id, used_percent: 20.0)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    scenario =
      fake_scenario(:budget_renew, healthy_snapshot(fresh_id), [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        claude_tool_start("toolu_3", source_event_id: "evt-claude-start"),
        Scenario.output_event("one", source_event_id: "evt-out-1"),
        claude_tool_end("toolu_3", source_event_id: "evt-claude-end"),
        Scenario.output_event("two", source_event_id: "evt-out-2"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    hold_before_first_event(pid)
    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    grant_for_run!(goal, run_id, fresh_id,
      response_budget: 2,
      tool_budget: 25,
      reserves: %{response: 0, tool: 0},
      checkpoint_cadence: 100,
      deadline: DateTime.add(FixedClock.now(), 3_600, :second)
    )

    release_elf(pid)

    assert_receive {:elf_terminal, ^run_id, %{class: :completed}}, 15_000

    # Exactly one renewal (mid-turn at the 2nd response spend; the outcome
    # finds the rearmed epoch below due), no suspend, no wake, and the
    # normal terminal checkpoint still lands.
    assert count_types(goal.id, run_id, ["lease.renewed"]) == 1
    assert count_types(goal.id, run_id, ["run.suspended"]) == 0
    assert reactive_checkpoint_count(goal.id, run_id) == 0
    assert terminal_checkpoint_count(goal.id, run_id) == 1

    ordered = ordered_events(goal.id, run_id)
    assert sequence_before?(ordered, {:harness, "evt-out-2"}, {"lease.renewed", nil})
    assert sequence_before?(ordered, {"lease.renewed", nil}, {:terminal, nil})
  end

  # LOCK (fails behaviourally on 1566acd and on e675c3b): the Elf half of
  # the compound shape from the committed trace
  # (normalized-codex-lease-stop-final.md: command end 141, bookkeeping
  # 142-143, fileChange start 144). Past the deadline, neither the command
  # END nor the write END may suspend: terminal-only declines at the turn
  # outcome, after proof the turn stopped. On 1566acd the Elf declines at
  # the command END; on e675c3b it declines at a tool END.
  test "a passed deadline across compound command/fileChange suspends only at the outcome",
       %{sup: sup, goal: goal, task: task} do
    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id, used_percent: 95.0)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    scenario =
      fake_scenario(:deadline_expire, breached_snapshot(fresh_id), [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        codex_command_start("cmd-1", source_event_id: "item-started-cmd-1"),
        command_event("cmd-1", "completed", source_event_id: "item-completed-cmd-1"),
        codex_file_change("fc-1", "inProgress", source_event_id: "item-started-fc-1"),
        codex_file_change("fc-1", "completed", source_event_id: "item-completed-fc-1"),
        delta_event(source_event_id: "evt-delta-after"),
        Scenario.output_event("after", source_event_id: "evt-out-after"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    hold_before_first_event(pid)
    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    grant_for_run!(goal, run_id, fresh_id,
      response_budget: 100,
      tool_budget: 100,
      reserves: %{response: 1, tool: 1},
      checkpoint_cadence: 100,
      deadline: DateTime.add(FixedClock.now(), -60, :second)
    )

    release_elf(pid)

    # The outcome consumed the decline: markers land, no terminal follows.
    wait_decline_wake(goal.id, run_id)

    assert count_types(goal.id, run_id, ["lease.expired"]) == 1
    assert reactive_checkpoint_count(goal.id, run_id) == 1
    assert count_types(goal.id, run_id, ["run.suspended"]) == 1

    ordered = ordered_events(goal.id, run_id)

    # Neither END suspended while work remained: expiry, checkpoint, and
    # suspension all follow the turn outcome.
    assert sequence_before?(ordered, {:harness, "evt-done"}, {"lease.expired", nil})

    assert sequence_before?(
             ordered,
             {:harness, "evt-done"},
             {"checkpoint.created", nil}
           )

    assert sequence_before?(ordered, {:harness, "evt-done"}, {"run.suspended", nil})
    assert no_terminal_event?(goal.id, run_id)
    refute_receive {:elf_terminal, ^run_id, _}
  end

  # LOCK (fails behaviourally on 1566acd and on e675c3b): an unknown item
  # shape (Codex normalizer `:lifecycle` fallback, e.g. `mcpToolCall`).
  # Past the deadline, a parallel command completion and a message
  # completion beside the still-open unknown tool must not decline — and
  # neither may any tool END: terminal-only declines at the turn outcome.
  # Neither old commit declines at the outcome (1566acd declines at the
  # message/START spend; e675c3b declines at a tool END).
  test "a passed deadline with an unknown tool open suspends only at the outcome",
       %{sup: sup, goal: goal, task: task} do
    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id, used_percent: 95.0)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    scenario =
      fake_scenario(:deadline_expire, breached_snapshot(fresh_id), [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        unknown_tool_start("mcp-1", "mcpToolCall", source_event_id: "item-started-mcp-1"),
        codex_command_start("cmd-1", source_event_id: "item-started-cmd-1"),
        command_event("cmd-1", "completed", source_event_id: "item-completed-cmd-1"),
        Scenario.output_event("mid", source_event_id: "evt-out-mid"),
        unknown_tool_end("mcp-1", "mcpToolCall", source_event_id: "item-completed-mcp-1"),
        delta_event(source_event_id: "evt-delta-after"),
        Scenario.output_event("after", source_event_id: "evt-out-after"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    hold_before_first_event(pid)
    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    grant_for_run!(goal, run_id, fresh_id,
      response_budget: 100,
      tool_budget: 100,
      reserves: %{response: 1, tool: 1},
      checkpoint_cadence: 100,
      deadline: DateTime.add(FixedClock.now(), -60, :second)
    )

    release_elf(pid)

    # The outcome consumed the decline: markers land, no terminal follows.
    wait_decline_wake(goal.id, run_id)

    assert count_types(goal.id, run_id, ["lease.expired"]) == 1
    assert reactive_checkpoint_count(goal.id, run_id) == 1
    assert count_types(goal.id, run_id, ["run.suspended"]) == 1

    ordered = ordered_events(goal.id, run_id)

    assert sequence_before?(ordered, {:harness, "evt-done"}, {"lease.expired", nil})

    assert sequence_before?(
             ordered,
             {:harness, "evt-done"},
             {"checkpoint.created", nil}
           )

    assert sequence_before?(ordered, {:harness, "evt-done"}, {"run.suspended", nil})
    assert no_terminal_event?(goal.id, run_id)
    refute_receive {:elf_terminal, ^run_id, _}
  end

  # LOCK (fails behaviourally on 1566acd and on e675c3b): a turn that
  # produces model activity and an outcome but never completes any tool
  # (the tool START is recorded; no END ever arrives). Past the deadline
  # with an exhausted-boundary spend absent entirely, nothing mid-turn may
  # decline; the outcome still yields the full decline sequence —
  # expiry, checkpoint naming the unfinished tool, suspension, and wake.
  # On both old commits no spend means no boundary, so no decline ever
  # fires (the interrupt-based design additionally needed a completion
  # that never comes).
  test "a passed deadline with an unfinished tool declines at the outcome",
       %{sup: sup, goal: goal, task: task} do
    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id, used_percent: 95.0)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    scenario =
      fake_scenario(:deadline_expire, breached_snapshot(fresh_id), [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        codex_command_start("cmd-1", source_event_id: "item-started-cmd-1"),
        delta_event(source_event_id: "evt-delta-mid"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    hold_before_first_event(pid)
    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    grant_for_run!(goal, run_id, fresh_id,
      response_budget: 100,
      tool_budget: 100,
      reserves: %{response: 1, tool: 1},
      checkpoint_cadence: 100,
      deadline: DateTime.add(FixedClock.now(), -60, :second)
    )

    release_elf(pid)

    # The outcome consumed the decline: markers land, no terminal follows.
    wait_decline_wake(goal.id, run_id)

    assert count_types(goal.id, run_id, ["lease.expired"]) == 1
    assert reactive_checkpoint_count(goal.id, run_id) == 1
    assert count_types(goal.id, run_id, ["run.suspended"]) == 1

    ordered = ordered_events(goal.id, run_id)

    # The checkpoint names the unfinished tool (its START is recorded with
    # no completion before the checkpoint).
    assert sequence_before?(ordered, {:harness, "evt-done"}, {"lease.expired", nil})

    assert sequence_before?(
             ordered,
             {:harness, "evt-done"},
             {"checkpoint.created", nil}
           )

    assert sequence_before?(ordered, {:harness, "evt-done"}, {"run.suspended", nil})
    assert no_terminal_event?(goal.id, run_id)
    refute_receive {:elf_terminal, ^run_id, _}
  end

  # LOCK (fails behaviourally on 1566acd and on e675c3b): the
  # completion→command-start shape (trace: commentary 139 → command 140).
  # Past the deadline, the message spend must not decline — and the
  # following command's whole lifecycle must not either. Terminal-only
  # declines at the outcome. On 1566acd the Elf declines at the message;
  # on e675c3b it declines at the command END.
  test "a passed deadline across message-then-command suspends only at the outcome",
       %{sup: sup, goal: goal, task: task} do
    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id, used_percent: 95.0)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    scenario =
      fake_scenario(:deadline_expire, breached_snapshot(fresh_id), [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        Scenario.output_event("mid", source_event_id: "evt-out-mid"),
        codex_command_start("cmd-1", source_event_id: "item-started-cmd-1"),
        command_event("cmd-1", "completed", source_event_id: "item-completed-cmd-1"),
        Scenario.output_event("after", source_event_id: "evt-out-after"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    hold_before_first_event(pid)
    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    grant_for_run!(goal, run_id, fresh_id,
      response_budget: 100,
      tool_budget: 100,
      reserves: %{response: 1, tool: 1},
      checkpoint_cadence: 100,
      deadline: DateTime.add(FixedClock.now(), -60, :second)
    )

    release_elf(pid)

    # The outcome consumed the decline: markers land, no terminal follows.
    wait_decline_wake(goal.id, run_id)

    assert count_types(goal.id, run_id, ["lease.expired"]) == 1
    assert reactive_checkpoint_count(goal.id, run_id) == 1
    assert count_types(goal.id, run_id, ["run.suspended"]) == 1

    ordered = ordered_events(goal.id, run_id)

    assert sequence_before?(ordered, {:harness, "evt-done"}, {"lease.expired", nil})

    assert sequence_before?(
             ordered,
             {:harness, "evt-done"},
             {"checkpoint.created", nil}
           )

    assert sequence_before?(ordered, {:harness, "evt-done"}, {"run.suspended", nil})
    assert no_terminal_event?(goal.id, run_id)
    refute_receive {:elf_terminal, ^run_id, _}
  end

  # N4 companion (session half lives in the Codex safe-boundary suite):
  # nil-typed lifecycle shapes are inert at the Elf layer — no tracking,
  # no spend — and a pending deadline still resolves only at the outcome.
  # Both layers fail closed consistently: neither acts early on shapes
  # without a usable type.
  test "nil item types never decline mid-turn; the outcome still declines",
       %{sup: sup, goal: goal, task: task} do
    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id, used_percent: 95.0)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    scenario =
      fake_scenario(:deadline_expire, breached_snapshot(fresh_id), [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        unknown_tool_start("nil-1", nil, source_event_id: "item-started-nil-1"),
        Scenario.output_event("mid", source_event_id: "evt-out-mid"),
        unknown_tool_end("nil-1", nil, source_event_id: "item-completed-nil-1"),
        Scenario.output_event("after", source_event_id: "evt-out-after"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    hold_before_first_event(pid)
    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    grant_for_run!(goal, run_id, fresh_id,
      response_budget: 100,
      tool_budget: 100,
      reserves: %{response: 1, tool: 1},
      checkpoint_cadence: 100,
      deadline: DateTime.add(FixedClock.now(), -60, :second)
    )

    release_elf(pid)

    # The outcome consumed the decline: markers land, no terminal follows.
    wait_decline_wake(goal.id, run_id)

    assert count_types(goal.id, run_id, ["lease.expired"]) == 1
    assert reactive_checkpoint_count(goal.id, run_id) == 1
    assert count_types(goal.id, run_id, ["run.suspended"]) == 1

    ordered = ordered_events(goal.id, run_id)

    assert sequence_before?(ordered, {:harness, "evt-done"}, {"lease.expired", nil})
    assert no_terminal_event?(goal.id, run_id)
    refute_receive {:elf_terminal, ^run_id, _}
  end

  # LOCK (fails at 8c97eb7 and at base c1ae4a8): the `/runs/new` shape. The
  # grant is committed (`lease.granted`) but nothing projects the goal, so
  # there is no lease ROW when the Elf starts. Live (final-acceptance.md
  # §5.1) such an Elf never loaded its lease: a 60 s manual lease ran for
  # 4 min 12 s with no due, no decline and no checkpoint before completion.
  test "a granted but unprojected lease is still enforced", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id, used_percent: 95.0)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    scenario =
      fake_scenario(:exhausted, breached_snapshot(fresh_id), [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        Scenario.output_event("one", source_event_id: "evt-out-1"),
        Scenario.output_event("two", source_event_id: "evt-out-2"),
        Scenario.output_event("three", source_event_id: "evt-out-3"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    hold_before_first_event(pid)
    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    %{grant_id: grant_id} =
      grant_for_run!(goal, run_id, fresh_id,
        response_budget: 2,
        tool_budget: 25,
        reserves: %{response: 0, tool: 0},
        checkpoint_cadence: 100,
        deadline: DateTime.add(FixedClock.now(), 3_600, :second),
        project: false
      )

    assert Repo.get(ExecutionLeaseRecord, grant_id) == nil

    release_elf(pid)

    # The Elf loaded the grant it was given and enforced it: exhaustion at
    # the 2nd output records the expiry mid-turn without suspending, and
    # the turn outcome completes the decline (suspend, no terminal).
    wait_decline_wake(goal.id, run_id)

    assert count_types(goal.id, run_id, ["lease.expired"]) == 1
    assert reactive_checkpoint_count(goal.id, run_id) == 1
    assert count_types(goal.id, run_id, ["run.suspended"]) == 1
    assert Repo.get(ExecutionLeaseRecord, grant_id) != nil
    assert no_terminal_event?(goal.id, run_id)
    refute_receive {:elf_terminal, ^run_id, _}
  end

  test "quota fast path expires immediately with zero spend and checkpoints", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    # sudden_quota_refusal shape: lifecycle, one partial output, then the
    # quota error. The provider already halted the turn, so the loop
    # re-evaluates immediately (no boundary wait) and checkpoints.
    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id, used_percent: 95.0)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    quota_error =
      Shoestring.Harness.Error.new(
        :quota_refused,
        "rate_limit_exceeded",
        "subscription limit reached"
      )

    scenario =
      fake_scenario(:quota, breached_snapshot(fresh_id), [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        Scenario.output_event("partial work", source_event_id: "evt-out-1"),
        Scenario.error_event(quota_error, source_event_id: "evt-quota")
      ])

    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    hold_before_first_event(pid)
    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    grant_for_run!(goal, run_id, fresh_id,
      response_budget: 10,
      tool_budget: 25,
      reserves: %{response: 1, tool: 1},
      checkpoint_cadence: 100,
      deadline: DateTime.add(FixedClock.now(), 3_600, :second)
    )

    release_elf(pid)

    assert_receive {:elf_terminal, ^run_id, _terminal}, 15_000

    assert count_types(goal.id, run_id, ["lease.expired"]) == 1
    assert count_types(goal.id, run_id, ["lease.checkpoint_required"]) == 1
    assert reactive_checkpoint_count(goal.id, run_id) == 1
    assert terminal_checkpoint_count(goal.id, run_id) == 1

    ordered = ordered_events(goal.id, run_id)

    assert sequence_before?(ordered, {:harness, "evt-quota"}, {"checkpoint.created", nil})

    assert sequence_before?(ordered, {"checkpoint.created", nil}, {:terminal, nil})
  end

  test "no-lease runs are unaffected (documentation)", %{sup: sup, goal: goal, task: task} do
    # No grant exists for this run: the loop must not account, mark, or
    # checkpoint anything, and the run completes exactly as before.
    request = ElvesHelpers.run_request(goal, task)
    scenario = Scenario.normal_completion()

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               notify: self()
             )

    assert_receive {:elf_terminal, run_id, %{class: :completed}}, 10_000

    assert count_types(goal.id, run_id, ["lease.renewal_due"]) == 0
    assert count_types(goal.id, run_id, ["lease.renewed"]) == 0
    assert count_types(goal.id, run_id, ["lease.expired"]) == 0
    assert count_types(goal.id, run_id, ["lease.checkpoint_required"]) == 0
    assert reactive_checkpoint_count(goal.id, run_id) == 0
    # I3 terminal checkpoint: every terminal appends exactly one repo-evidence
    # checkpoint before the terminal event, even when the loop wrote none.
    assert terminal_checkpoint_count(goal.id, run_id) == 1
    assert ElvesHelpers.terminal_event(goal.id, run_id).type == "run.completed"
  end

  test "lifecycle noise under lease spends nothing (documentation)", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    # A leased run that only ever handshakes: no spend, no due, no renewal,
    # no checkpoint — the existing no_adapter_progress failure stands.
    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    scenario =
      fake_scenario(:handshake_only, healthy_snapshot(fresh_id), [
        Scenario.lifecycle_event(source_event_id: "evt-life-1"),
        Scenario.lifecycle_event(source_event_id: "evt-life-2"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    hold_before_first_event(pid)
    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    grant_for_run!(goal, run_id, fresh_id,
      response_budget: 10,
      tool_budget: 25,
      reserves: %{response: 1, tool: 1},
      checkpoint_cadence: 100,
      deadline: DateTime.add(FixedClock.now(), 3_600, :second)
    )

    release_elf(pid)

    assert_receive {:elf_terminal, ^run_id, _terminal}, 15_000

    assert count_types(goal.id, run_id, ["lease.renewal_due"]) == 0
    assert count_types(goal.id, run_id, ["lease.renewed"]) == 0
    assert count_types(goal.id, run_id, ["lease.expired"]) == 0
    assert reactive_checkpoint_count(goal.id, run_id) == 0
    # I3 terminal checkpoint: every terminal appends exactly one repo-evidence
    # checkpoint before the terminal event, even when the loop wrote none.
    assert terminal_checkpoint_count(goal.id, run_id) == 1
    assert Repo.get_by!(ExecutionLeaseRecord, run_id: run_id).status == "active"
  end

  # -- Helpers --

  # Each test grants its lease to the Elf's own run, which exists only once
  # the Elf has started. The scripted events then arrive on @interval_ms
  # timers, so a grant racing them could land after the boundary it is
  # meant to govern (CI 36063514995: ElfLeaseLoopTest:231, no
  # `lease.renewed`; CI 36062741394: ElfLeaseLoopTest:296, the precondition
  # read `renewal_due`). `start_run` returns once `init/1` has run, so this
  # suspend is queued behind the launch continuation and is served before
  # any event timer message: the Elf ingests nothing until `release_elf/1`,
  # whatever the machine's load.
  defp hold_before_first_event(pid), do: :ok = :sys.suspend(pid, 30_000)

  defp release_elf(pid), do: :ok = :sys.resume(pid, 30_000)

  # Synchronizes on the LAST durable marker of the decline chain
  # (expired → checkpoint → suspend → wake): by the time the wake row is
  # durable, every earlier marker is too. A decline consumed its turn
  # outcome, so no terminal verdict follows — assert that absence only
  # after this wait, when any terminal notification would already be
  # queued.
  defp wait_decline_wake(_goal_id, run_id) do
    assert {:ok, wake} =
             ElvesHelpers.wait_until(fn -> Repo.get_by(WakeupRecord, run_id: run_id) end)

    assert wake.status == "scheduled"
  end

  defp no_terminal_event?(goal_id, run_id) do
    not Enum.any?(ordered_events(goal_id, run_id), fn
      {:terminal, _} -> true
      _ -> false
    end)
  end

  defp wait_running(goal, dispatch_id) do
    assert {:ok, run_id} =
             ElvesHelpers.wait_until(fn -> ElvesHelpers.run_id_for_dispatch(dispatch_id) end)

    assert {:ok, _pgid} =
             ElvesHelpers.wait_until(fn -> ElvesHelpers.recorded_pgid(goal.id, run_id) end)

    run_id
  end

  defp fake_scenario(name, capacity, events) do
    %Scenario{
      name: name,
      capacity: capacity,
      start_error: nil,
      resume_error: nil,
      provider_session_id: "fake-session-#{name}",
      events: events,
      delivery_modifier: :none
    }
  end

  defp tool_event(opts) do
    %{
      kind: :tool,
      offset_ms: Keyword.get(opts, :offset_ms, 0),
      source_event_id: Keyword.fetch!(opts, :source_event_id),
      error: nil,
      result: nil,
      capacity_snapshot: nil,
      extensions: %{"shoestring.fake:tool" => "read"}
    }
  end

  # Explicit lifecycle boundary markers mirror what the Codex normalizer
  # records from the raw RPC method. `command_event/3` is used for both
  # starts and ends across these tests, so the marker derives from the
  # status it expresses; genuinely ambiguous shapes have no marker at all.
  defp command_event(item_id, status, opts) do
    %{
      kind: :command,
      offset_ms: Keyword.get(opts, :offset_ms, 0),
      source_event_id: Keyword.fetch!(opts, :source_event_id),
      error: nil,
      result: nil,
      capacity_snapshot: nil,
      extensions: %{
        "codex-app-server:item_id" => item_id,
        "codex-app-server:status" => status,
        "codex-app-server:exit_code" => 0
      }
    }
  end

  defp codex_file_change(item_id, status, opts) do
    %{
      kind: :tool,
      offset_ms: Keyword.get(opts, :offset_ms, 0),
      source_event_id: Keyword.fetch!(opts, :source_event_id),
      error: nil,
      result: nil,
      capacity_snapshot: nil,
      extensions: %{
        "codex-app-server:item_id" => item_id,
        "codex-app-server:tool" => "fileChange",
        "codex-app-server:status" => status
      }
    }
  end

  # A Codex command START: in-progress status with no exit code spends
  # nothing. The pre-existing `command_event/3` always carries
  # `exit_code: 0`, so it can only express completions.
  defp codex_command_start(item_id, opts) do
    %{
      kind: :command,
      offset_ms: Keyword.get(opts, :offset_ms, 0),
      source_event_id: Keyword.fetch!(opts, :source_event_id),
      error: nil,
      result: nil,
      capacity_snapshot: nil,
      extensions: %{
        "codex-app-server:item_id" => item_id,
        "codex-app-server:status" => "inProgress"
      }
    }
  end

  # An unknown Codex item shape (normalizer `:lifecycle` fallback, e.g.
  # `mcpToolCall`): kind `:lifecycle` with identity and the recorded type.
  # Terminal-only decline never fires mid-turn, so these shapes simply
  # ride along as spend-neutral evidence until the turn outcome.
  defp unknown_tool_start(item_id, item_type, opts) do
    %{
      kind: :lifecycle,
      offset_ms: Keyword.get(opts, :offset_ms, 0),
      source_event_id: Keyword.fetch!(opts, :source_event_id),
      error: nil,
      result: nil,
      capacity_snapshot: nil,
      extensions: %{
        "codex-app-server:item_id" => item_id,
        "codex-app-server:item_type" => item_type
      }
    }
  end

  defp unknown_tool_end(item_id, item_type, opts) do
    %{
      kind: :lifecycle,
      offset_ms: Keyword.get(opts, :offset_ms, 0),
      source_event_id: Keyword.fetch!(opts, :source_event_id),
      error: nil,
      result: nil,
      capacity_snapshot: nil,
      extensions: %{
        "codex-app-server:item_id" => item_id,
        "codex-app-server:item_type" => item_type
      }
    }
  end

  defp claude_tool_start(tool_use_id, opts) do
    %{
      kind: :command,
      offset_ms: Keyword.get(opts, :offset_ms, 0),
      source_event_id: Keyword.fetch!(opts, :source_event_id),
      error: nil,
      result: nil,
      capacity_snapshot: nil,
      extensions: %{
        "claude-headless:boundary" => "start",
        "claude-headless:tool_use_id" => tool_use_id,
        "claude-headless:tool_name" => "Bash"
      }
    }
  end

  defp claude_tool_end(tool_use_id, opts) do
    %{
      kind: :command,
      offset_ms: Keyword.get(opts, :offset_ms, 0),
      source_event_id: Keyword.fetch!(opts, :source_event_id),
      error: nil,
      result: nil,
      capacity_snapshot: nil,
      extensions: %{
        "claude-headless:boundary" => "end",
        "claude-headless:tool_use_id" => tool_use_id,
        "claude-headless:status" => "completed"
      }
    }
  end

  defp delta_event(opts) do
    %{
      kind: :output,
      offset_ms: Keyword.get(opts, :offset_ms, 0),
      source_event_id: Keyword.fetch!(opts, :source_event_id),
      error: nil,
      result: nil,
      capacity_snapshot: nil,
      extensions: %{
        "codex-app-server:method" => "item/agentMessage/delta",
        "codex-app-server:delta" => "partial"
      }
    }
  end

  defp healthy_snapshot(snapshot_id), do: codex_snapshot(snapshot_id, 20.0)

  defp breached_snapshot(snapshot_id), do: codex_snapshot(snapshot_id, 95.0)

  defp codex_snapshot(snapshot_id, used_percent) do
    now = FixedClock.now()

    {:ok, snapshot} =
      CapacitySnapshot.new(
        %{
          version: 2,
          snapshot_id: snapshot_id,
          capacity_state: :observed,
          windows: [
            %{kind: "five_hour", state: :observed, used_percent: used_percent, reset_at: nil},
            %{kind: "weekly", state: :observed, used_percent: 30.0, reset_at: nil}
          ],
          observed_at: now,
          freshness: %{max_age_seconds: 300},
          source: %{
            adapter_id: "shoestring.harness.fake",
            provider_id: "codex",
            invocation_mode: "app_server",
            event: :explicit_read
          },
          scope: "account:codex",
          confidence: :high,
          support_tier: :proactive,
          compatibility_state: :compatible,
          reason: nil,
          extensions: %{}
        },
        now: now
      )

    snapshot
  end

  defp grant_for_run!(goal, run_id, admitted_snapshot_id, opts) do
    decision_id = Ecto.UUID.generate()
    grant_id = Ecto.UUID.generate()

    admission =
      CobblerHelpers.append_admission_event!(
        goal.id,
        CobblerHelpers.admission_payload()
        |> Map.merge(%{
          "decision_id" => decision_id,
          "result" => "admit",
          "reason_code" => "automatic_admission_eligible",
          "explanation" => "Elf lease loop test admission",
          "observation" => %{
            "snapshot_id" => admitted_snapshot_id,
            "confidence" => "high",
            "freshness" => "fresh"
          },
          "proposed_bounds" => %{
            "response_budget" => Keyword.fetch!(opts, :response_budget),
            "tool_budget" => Keyword.fetch!(opts, :tool_budget),
            "deadline" => DateTime.to_iso8601(Keyword.fetch!(opts, :deadline)),
            "checkpoint_cadence" => Keyword.fetch!(opts, :checkpoint_cadence),
            "reserves" => %{
              "response" => get_in(opts, [:reserves, :response]),
              "tool" => get_in(opts, [:reserves, :tool])
            }
          }
        })
      )

    reserves = Keyword.fetch!(opts, :reserves)

    {:ok, lease} =
      ExecutionLease.new(%{
        version: 1,
        grant_id: grant_id,
        run_id: run_id,
        admitted_snapshot_id: admitted_snapshot_id,
        reserves: %{response: reserves.response, tool: reserves.tool},
        response_budget: Keyword.fetch!(opts, :response_budget),
        tool_budget: Keyword.fetch!(opts, :tool_budget),
        deadline: Keyword.fetch!(opts, :deadline),
        checkpoint_cadence: Keyword.fetch!(opts, :checkpoint_cadence),
        renewal_state: :none,
        extensions: %{
          "cobbler.lease:admission_decision_id" => decision_id,
          "cobbler.lease:admission_event_id" => admission.id,
          "cobbler.lease:candidate" => "codex/codex_app_server",
          "cobbler.lease:scope" => "account:codex"
        }
      })

    assert {:ok, %{grant_id: ^grant_id}} = Leases.grant(goal.id, lease)

    if Keyword.get(opts, :project, true) do
      assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)
      assert Repo.get!(ExecutionLeaseRecord, grant_id).status == "active"
    end

    %{grant_id: grant_id, admission_id: admission.id}
  end

  defp count_types(goal_id, run_id, types) do
    ElvesHelpers.count_events(goal_id, run_id, types)
  end

  # I2 loop checkpoints vs I3 terminal checkpoints: the reactive path carries
  # no terminal-kind extension; the terminal path always does, so the two
  # counts partition `checkpoint.created` exactly.
  defp reactive_checkpoint_count(goal_id, run_id) do
    checkpoint_events(goal_id, run_id)
    |> Enum.count(fn event ->
      event.payload["extensions"]["shoestring.elf:checkpoint_kind"] != "terminal"
    end)
  end

  defp terminal_checkpoint_count(goal_id, run_id) do
    checkpoint_events(goal_id, run_id)
    |> Enum.count(fn event ->
      event.payload["extensions"]["shoestring.elf:checkpoint_kind"] == "terminal"
    end)
  end

  defp checkpoint_events(goal_id, run_id) do
    Repo.all(
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^goal_id and event.run_id == ^run_id and
            event.type == "checkpoint.created",
        order_by: [asc: event.sequence]
    )
  end

  defp ordered_events(goal_id, run_id) do
    Repo.all(
      from event in TrajectoryEvent,
        where: event.goal_id == ^goal_id and event.run_id == ^run_id,
        order_by: [asc: event.sequence],
        select: {event.sequence, event.type, event.payload}
    )
    |> Enum.map(fn {_sequence, type, payload} ->
      cond do
        type == "harness.event_recorded" ->
          {:harness, payload["source_event_id"]}

        type in ["run.completed", "run.failed", "run.interrupted", "run.cancelled"] ->
          {:terminal, nil}

        true ->
          {type, nil}
      end
    end)
  end

  defp sequence_before?(ordered, left, right) do
    left_index = Enum.find_index(ordered, &(&1 == left))
    right_index = Enum.find_index(ordered, &(&1 == right))

    assert left_index != nil, "expected event #{inspect(left)} in #{inspect(ordered)}"
    assert right_index != nil, "expected event #{inspect(right)} in #{inspect(ordered)}"
    left_index < right_index
  end
end
