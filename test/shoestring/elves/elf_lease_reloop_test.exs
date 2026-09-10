defmodule Shoestring.Elves.ElfLeaseReloopTest do
  @moduledoc """
  Hermetic Elf lease re-loop tests (round-2 finding 4 follow-up).

  The I2 loop was single-shot: `renew_path` short-circuited on
  `lease_settled?` after the first renewal, decline wrote a checkpoint but
  never suspended the run or scheduled sleep, and `stop_path` set
  `lease_stop_requested?` even on `within_lease`. Each test drives the real
  `Shoestring.Elves.Elf` ingest path with Fake scripted streams and
  `FixedClock` — never a provider CLI, never the network. (`ManualClock`
  is process-dictionary local, so the cross-process Elf ingest path uses
  `FixedClock`, following the I2 precedent.)

  Lock vs documentation ledger (standing contract — verified against base
  `4d2df5a`):

  - second exhaustion re-renews: **lock**. Base settles after the first
    renewal, so the probe runs once and the grant stays chained to the
    first snapshot (`calls == 1`, `admitted == S1`).
  - decline suspends + sleep wake: **lock**. Base never appends
    `run.suspended` and never schedules a wakeup row.
  - quota decline twin: **lock**, same reason.
  - budget-due renews with no session stop: the trajectory half
    (`lease.renewed`, zero stop calls) passes on base (**documentation**);
    the stop-flag hygiene half (`lease_stop_requested?` stays clear)
    **fails on base** (**lock**).
  - deadline path requests the session stop: passes on base
    (**documentation** — locks the preserved deadline behavior).
  """

  use Shoestring.DataCase, async: false

  import Ecto.Query

  alias Shoestring.Cobbler.{Leases, WakeupRecord}
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
  alias Shoestring.Test.ScriptedProbeFake
  alias Shoestring.Trajectory.TrajectoryEvent

  @runner_opts [kill_grace_ms: 200, reap_timeout_ms: 2_000]
  @interval_ms 200
  @session_table :codex_app_server_sessions

  setup do
    sup = start_supervised!({Shoestring.Elves.Supervisor, name: nil})
    %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()
    {:ok, sup: sup, goal: goal, task: task}
  end

  test "second exhaustion re-renews against a fresh snapshot each epoch", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    # response_budget 4, reserve 1 → due at the 3rd completion of each epoch:
    # out-3 renews epoch 1, out-6 renews epoch 2.
    admitted_id = Ecto.UUID.generate()
    fresh_s1 = Ecto.UUID.generate()
    fresh_s2 = Ecto.UUID.generate()

    for snapshot_id <- [admitted_id, fresh_s1, fresh_s2] do
      FakeHelpers.append_capacity_snapshot(goal, snapshot_id)
    end

    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    agent =
      start_supervised!(
        {Agent, fn -> %{calls: 0, snapshots: [snap1(fresh_s1), snap2(fresh_s2)]} end}
      )

    scenario =
      fake_scenario(:two_epochs, snap1(fresh_s1), [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        Scenario.output_event("one", source_event_id: "evt-out-1"),
        Scenario.output_event("two", source_event_id: "evt-out-2"),
        Scenario.output_event("three", source_event_id: "evt-out-3"),
        Scenario.output_event("four", source_event_id: "evt-out-4"),
        Scenario.output_event("five", source_event_id: "evt-out-5"),
        Scenario.output_event("six", source_event_id: "evt-out-6"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               adapter: ScriptedProbeFake,
               adapter_opts: %{scenario: scenario, probe_script: agent},
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    grant_for_run!(goal, run_id, admitted_id,
      response_budget: 4,
      tool_budget: 25,
      reserves: %{response: 1, tool: 1},
      checkpoint_cadence: 100,
      deadline: DateTime.add(FixedClock.now(), 3_600, :second)
    )

    assert_receive {:elf_terminal, ^run_id, %{class: :completed}}, 15_000

    # The renewal sequence re-observed fresh capacity once per epoch: two
    # probes, and the grant ends chained to the SECOND epoch's snapshot.
    # (Base: one probe, chained to fresh_s1.)
    assert ScriptedProbeFake.calls(agent) == 2
    assert Repo.get_by!(ExecutionLeaseRecord, run_id: run_id).admitted_snapshot_id == fresh_s2

    # Lease events stay idempotent per grant key: exactly one durable
    # renewal_due / renewed pair across both epochs (replays, not dupes).
    assert count_types(goal.id, run_id, ["lease.renewal_due"]) == 1
    assert count_types(goal.id, run_id, ["lease.renewed"]) == 1
    assert reactive_checkpoint_count(goal.id, run_id) == 0
    assert terminal_checkpoint_count(goal.id, run_id) == 1

    ordered = ordered_events(goal.id, run_id)
    assert sequence_before?(ordered, {:harness, "evt-out-3"}, {"lease.renewed", nil})
    assert sequence_before?(ordered, {"lease.renewed", nil}, {:harness, "evt-out-4"})

    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)
    assert Repo.get_by!(ExecutionLeaseRecord, run_id: run_id).status == "renewed"
  end

  test "decline suspends the run and schedules a sleep wake", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    # response_budget 2, zero reserve: the 2nd output exhausts the allowance
    # in-flight with breached capacity, so the boundary declines: checkpoint
    # contents, run.pausing/run.suspended, and a durable sleep wake — while
    # the remaining items still flow to a normal terminal.
    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id, used_percent: 95.0)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    scenario =
      fake_scenario(:decline_sleep, breached_snapshot(fresh_id), [
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

    assert_receive {:elf_terminal, ^run_id, _terminal}, 15_000

    # The run slept at the decline boundary: pausing then suspended, after
    # the exhausting item and before the items that still flowed. (Base:
    # zero of each.)
    assert count_types(goal.id, run_id, ["run.pausing"]) == 1
    assert count_types(goal.id, run_id, ["run.suspended"]) == 1
    assert count_types(goal.id, run_id, ["lease.expired"]) == 1
    assert count_types(goal.id, run_id, ["lease.checkpoint_required"]) == 1
    assert reactive_checkpoint_count(goal.id, run_id) == 1

    ordered = ordered_events(goal.id, run_id)
    assert sequence_before?(ordered, {:harness, "evt-out-2"}, {"checkpoint.created", nil})
    assert sequence_before?(ordered, {"checkpoint.created", nil}, {"run.suspended", nil})
    assert sequence_before?(ordered, {"run.suspended", nil}, {:harness, "evt-out-3"})

    # Nothing was interrupted mid-item: the 3rd output and the verdict
    # still landed after the suspend.
    assert count_types(goal.id, run_id, ["harness.event_recorded"]) == 5

    # The sleep wake: one durable row for this run, firing at the admission
    # delayed-recheck default past now, under the synthetic decline key.
    # (Base: no row.)
    wakeup = Repo.get_by!(WakeupRecord, run_id: run_id)
    assert wakeup.goal_id == goal.id
    assert wakeup.command_id == "elf-lease-decline:#{request.dispatch_id}"
    assert wakeup.reason == "lease_decline_recheck"
    assert wakeup.status == "scheduled"

    assert DateTime.compare(
             wakeup.wake_at,
             DateTime.add(FixedClock.now(), 60, :second)
           ) == :eq

    # Projection applies the suspend (the run row reads suspended, which is
    # what the wakeup resume path requires) and then halts at the
    # post-suspend terminal: `suspended → complete` is not a legal
    # `RunStateMachine` edge. That halt is a known load-bearing limitation
    # for the projector-owning track (see the evidence note) — asserted
    # here explicitly rather than smuggled in as a green `{:ok, _}`.
    assert {:error, _} = Projector.project(goal.id, clock: FixedClock)
    assert Repo.get_by!(RunRecord, id: run_id).status == "suspended"

    assert Repo.get_by!(ExecutionLeaseRecord, run_id: run_id).status ==
             "checkpoint_required"
  end

  test "quota refusal decline suspends and schedules a sleep wake", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    # Twin of the boundary decline through the quota fast path: the provider
    # already halted the turn, so the loop re-evaluates immediately and —
    # on breached capacity — declines into the same suspend + sleep shape.
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
      fake_scenario(:quota_decline, breached_snapshot(fresh_id), [
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

    # (Base: zero suspend events, no wakeup row.)
    assert count_types(goal.id, run_id, ["run.pausing"]) == 1
    assert count_types(goal.id, run_id, ["run.suspended"]) == 1
    assert count_types(goal.id, run_id, ["lease.expired"]) == 1
    assert count_types(goal.id, run_id, ["lease.checkpoint_required"]) == 1
    assert reactive_checkpoint_count(goal.id, run_id) == 1

    wakeup = Repo.get_by!(WakeupRecord, run_id: run_id)
    assert wakeup.goal_id == goal.id
    assert wakeup.command_id == "elf-lease-decline:#{request.dispatch_id}"
    assert wakeup.status == "scheduled"

    assert DateTime.compare(
             wakeup.wake_at,
             DateTime.add(FixedClock.now(), 60, :second)
           ) == :eq
  end

  test "budget-due renews at the boundary with no session stop", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    # response_budget 4, reserve 1 → due at the 3rd output with a live
    # deadline: no session stop is required, and none may happen. A live
    # session double is registered so a spurious stop would be observed.
    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    scenario =
      fake_scenario(:budget_no_stop, healthy_snapshot(fresh_id), [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        Scenario.output_event("one", source_event_id: "evt-out-1"),
        Scenario.output_event("two", source_event_id: "evt-out-2"),
        Scenario.output_event("three", source_event_id: "evt-out-3"),
        Scenario.output_event("four", source_event_id: "evt-out-4"),
        Scenario.output_event("five", source_event_id: "evt-out-5"),
        Scenario.output_event("six", source_event_id: "evt-out-6"),
        Scenario.output_event("seven", source_event_id: "evt-out-7"),
        Scenario.output_event("eight", source_event_id: "evt-out-8"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, elf_pid} =
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

    register_session_double(run_id)

    # Stop-flag hygiene FIRST, while the Elf is still streaming the tail:
    # the flag is set only on an actual `:stop_requested`, so with a live
    # deadline it stays clear. (Base sets it on the `within_lease`
    # answer — lock.)
    assert {:ok, true} =
             ElvesHelpers.wait_until(fn ->
               if count_types(goal.id, run_id, ["lease.renewed"]) == 1, do: true
             end)

    assert Process.alive?(elf_pid)
    assert :sys.get_state(elf_pid).lease_stop_requested? == false

    assert_receive {:elf_terminal, ^run_id, %{class: :completed}}, 15_000

    # Renewed at the boundary with the session untouched: no safe-stop was
    # ever requested (passes on base too — documentation of the no-stop
    # intent).
    assert count_types(goal.id, run_id, ["lease.renewal_due"]) == 1
    assert count_types(goal.id, run_id, ["lease.renewed"]) == 1
    refute_received :safe_stop_requested
  end

  test "deadline path still requests the session stop", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    # The deadline is already past with a live session double: the safe
    # stop must be requested before the boundary renewal runs. (Passes on
    # base — documentation locking the preserved deadline behavior.)
    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    scenario =
      fake_scenario(:deadline_stop, healthy_snapshot(fresh_id), [
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
      response_budget: 100,
      tool_budget: 100,
      reserves: %{response: 1, tool: 1},
      checkpoint_cadence: 100,
      deadline: DateTime.add(FixedClock.now(), -60, :second)
    )

    register_session_double(run_id)

    assert_receive {:elf_terminal, ^run_id, %{class: :completed}}, 15_000

    assert_received :safe_stop_requested
    assert count_types(goal.id, run_id, ["lease.renewal_due"]) == 1
    assert count_types(goal.id, run_id, ["lease.renewed"]) == 1
    assert reactive_checkpoint_count(goal.id, run_id) == 0
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

  # Registers a live session double for `run_id` in the Codex session
  # table: it answers `request_safe_stop` with `:stop_requested` and
  # notifies the test, so stop/no-stop behavior is observable without a
  # provider process. Hermetic and deterministic; cleaned up on exit.
  defp register_session_double(run_id) do
    _ = Shoestring.Harness.CodexAppServer.lookup_session(Ecto.UUID.generate())

    test = self()
    double = spawn(fn -> session_double_loop(test) end)

    :ets.insert(@session_table, {run_id, double})

    on_exit(fn ->
      # The table is owned by whichever process created it first (test or
      # Elf); a dead owner destroys it, so the delete must tolerate absence.
      if :ets.info(@session_table) != :undefined do
        :ets.delete(@session_table, run_id)
      end

      if Process.alive?(double), do: Process.exit(double, :kill)
    end)

    :ok
  end

  defp session_double_loop(test) do
    receive do
      {:"$gen_call", {caller, ref}, :request_safe_stop} ->
        send(test, :safe_stop_requested)
        send(caller, {ref, {:ok, :stop_requested}})
        session_double_loop(test)
    end
  end

  defp healthy_snapshot(snapshot_id), do: codex_snapshot(snapshot_id, 20.0)

  defp breached_snapshot(snapshot_id), do: codex_snapshot(snapshot_id, 95.0)

  defp snap1(snapshot_id), do: codex_snapshot(snapshot_id, 20.0)
  defp snap2(snapshot_id), do: codex_snapshot(snapshot_id, 22.0)

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
          "explanation" => "Elf lease re-loop test admission",
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
