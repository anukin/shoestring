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

  alias Shoestring.Cobbler.Leases
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

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    grant_for_run!(goal, run_id, fresh_id,
      response_budget: 4,
      tool_budget: 25,
      reserves: %{response: 1, tool: 1},
      checkpoint_cadence: 100,
      deadline: DateTime.add(FixedClock.now(), 3_600, :second)
    )

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
    assert Repo.get_by!(ExecutionLeaseRecord, run_id: run_id).status == "renewed"
    assert Repo.get_by!(ExecutionLeaseRecord, run_id: run_id).admitted_snapshot_id == fresh_id
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

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    grant_for_run!(goal, run_id, fresh_id,
      response_budget: 100,
      tool_budget: 3,
      reserves: %{response: 1, tool: 1},
      checkpoint_cadence: 100,
      deadline: DateTime.add(FixedClock.now(), 3_600, :second)
    )

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

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    grant_for_run!(goal, run_id, fresh_id,
      response_budget: 3,
      tool_budget: 25,
      reserves: %{response: 1, tool: 1},
      checkpoint_cadence: 100,
      deadline: DateTime.add(FixedClock.now(), 3_600, :second)
    )

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
    # The deadline is already past: the first item.completed boundary must
    # mark renewal_due and renew (healthy fresh capacity).
    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    scenario =
      fake_scenario(:deadline_renew, healthy_snapshot(fresh_id), [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        Scenario.output_event("work", source_event_id: "evt-out-1"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    grant_for_run!(goal, run_id, fresh_id,
      response_budget: 100,
      tool_budget: 100,
      reserves: %{response: 1, tool: 1},
      checkpoint_cadence: 100,
      deadline: DateTime.add(FixedClock.now(), -60, :second)
    )

    assert_receive {:elf_terminal, ^run_id, %{class: :completed}}, 15_000

    assert count_types(goal.id, run_id, ["lease.renewal_due"]) == 1
    assert count_types(goal.id, run_id, ["lease.renewed"]) == 1

    ordered = ordered_events(goal.id, run_id)

    # The deadline had already passed, so due is marked on the first
    # ingested event (even the lifecycle handshake); the renewal itself
    # still waits for the item.completed boundary.
    assert sequence_before?(ordered, {:harness, "evt-life"}, {"lease.renewal_due", nil})
    assert sequence_before?(ordered, {:harness, "evt-out-1"}, {"lease.renewed", nil})
    assert sequence_before?(ordered, {"lease.renewal_due", nil}, {"lease.renewed", nil})

    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    record = Repo.get_by!(ExecutionLeaseRecord, run_id: run_id)
    assert record.status == "renewed"
    assert record.admitted_snapshot_id == fresh_id
  end

  test "refused renewal expires then checkpoints at the boundary without interrupting the item",
       %{sup: sup, goal: goal, task: task} do
    # Breached fresh capacity: the first item.completed boundary expires the
    # lease, requires a checkpoint, and writes checkpoint contents — while
    # the remaining items still flow (no mid-item interrupt).
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

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    grant_for_run!(goal, run_id, fresh_id,
      response_budget: 100,
      tool_budget: 100,
      reserves: %{response: 1, tool: 1},
      checkpoint_cadence: 100,
      deadline: DateTime.add(FixedClock.now(), -60, :second)
    )

    assert_receive {:elf_terminal, ^run_id, _terminal}, 15_000

    assert count_types(goal.id, run_id, ["lease.expired"]) == 1
    assert count_types(goal.id, run_id, ["lease.checkpoint_required"]) == 1
    assert reactive_checkpoint_count(goal.id, run_id) == 1
    assert terminal_checkpoint_count(goal.id, run_id) == 1

    ordered = ordered_events(goal.id, run_id)

    assert sequence_before?(ordered, {"lease.expired", nil}, {"lease.checkpoint_required", nil})

    # The reactive checkpoint lands at the safe boundary: the completing
    # item is durable first, and the terminal comes after the checkpoint.
    assert sequence_before?(ordered, {:harness, "evt-out-1"}, {"checkpoint.created", nil})

    assert sequence_before?(
             ordered,
             {"checkpoint.created", nil},
             {:terminal, nil}
           )

    # Nothing was interrupted mid-item: both outputs and the verdict landed.
    assert count_types(goal.id, run_id, ["harness.event_recorded"]) == 4

    # Intended re-loop change (round-2 finding 4, P2): decline now suspends
    # the run (`run.pausing`/`run.suspended`) before the verdict's terminal
    # lands. `suspended → complete` is a legal `RunStateMachine` edge, so
    # harness projection advances through the terminal instead of halting.
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)
    assert Repo.get_by!(RunRecord, id: run_id).status == "completed"
    assert Repo.get_by!(ExecutionLeaseRecord, run_id: run_id).status == "checkpoint_required"
  end

  test "in-flight exhaustion checkpoints at the boundary; the turn still completes", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    # response_budget 2, zero reserve: the 2nd output exhausts the allowance
    # in-flight. The loop must checkpoint at that boundary while the 3rd
    # output and the verdict still flow to a normal completion.
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

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    grant_for_run!(goal, run_id, fresh_id,
      response_budget: 2,
      tool_budget: 25,
      reserves: %{response: 0, tool: 0},
      checkpoint_cadence: 100,
      deadline: DateTime.add(FixedClock.now(), 3_600, :second)
    )

    assert_receive {:elf_terminal, ^run_id, %{class: :completed}}, 15_000

    assert count_types(goal.id, run_id, ["lease.expired"]) == 1
    assert reactive_checkpoint_count(goal.id, run_id) == 1
    assert terminal_checkpoint_count(goal.id, run_id) == 1

    ordered = ordered_events(goal.id, run_id)

    # Exhaustion hit exactly at the 2nd output: the checkpoint follows that
    # boundary, and the 3rd output plus the terminal still land after it.
    assert sequence_before?(ordered, {:harness, "evt-out-2"}, {"checkpoint.created", nil})

    assert sequence_before?(ordered, {"checkpoint.created", nil}, {:harness, "evt-out-3"})

    assert sequence_before?(ordered, {"checkpoint.created", nil}, {:terminal, nil})
    assert count_types(goal.id, run_id, ["harness.event_recorded"]) == 5
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

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    grant_for_run!(goal, run_id, fresh_id,
      response_budget: 10,
      tool_budget: 25,
      reserves: %{response: 1, tool: 1},
      checkpoint_cadence: 100,
      deadline: DateTime.add(FixedClock.now(), 3_600, :second)
    )

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

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    grant_for_run!(goal, run_id, fresh_id,
      response_budget: 10,
      tool_budget: 25,
      reserves: %{response: 1, tool: 1},
      checkpoint_cadence: 100,
      deadline: DateTime.add(FixedClock.now(), 3_600, :second)
    )

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
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)
    assert Repo.get!(ExecutionLeaseRecord, grant_id).status == "active"

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
