defmodule Shoestring.Cobbler.ObservatorySnapshotTwinsTest do
  @moduledoc """
  The renewal and wake twins of #79's handoff snapshot fix, driven with the
  reading production actually hands them: one the `Shoestring.Harness.Observatory`
  ledger already owns.

  In production the Elf's renewal probe (`CodexAppServer.probe/1` →
  `CodexMonitor.observe/1`) returns the monitor's current snapshot, which the
  monitor has already ingested into the ledger, and the wake probe
  (`Shoestring.Cobbler.WakeupObserve`, the `:prod` `:wakeup_observe` MFA)
  serves ledger snapshots directly. Every such snapshot is projected as a
  `CapacitySnapshotRecord` owned by the protected Observatory goal. Here each
  reading is ingested through the real `Observatory.ingest/2` and handed to the
  flow unchanged — no hand-built goal-local id.

  ## The defect these lock (base `d3fa152`)

  `LeaseRenewal.persist_renewal_snapshot/5` and `Wakeups.persist_snapshot/6`
  re-appended that reading under the WORK goal with its ORIGINAL id. The
  projector found a row owned by another goal and failed with
  `{:capacity_snapshot_not_owned, id}`, leaving the goal's `harness` projector
  `failed` for good. Live, that left `run.completed` and the terminal
  `checkpoint.created` unprojected, so a later `run.handoff` was rejected with
  `handoff_checkpoint_not_found` (`live-production-rerun.md` §3.2).

  Every test marked LOCK fails on base for that behavioural reason
  (`capacity_snapshot_not_owned` / a `failed` projector position / a missing
  checkpoint row), not on a missing function. Tests marked DOC pass on base and
  are documentation: they pin properties the fix must not break.

  Hermetic: FixedClock/ManualClock, the real Observatory ledger in the test
  repo, the Fake adapter for the one Elf test. Never a provider CLI, never the
  network.
  """
  use Shoestring.DataCase, async: false

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers

  alias Oban.Job

  alias Shoestring.Cobbler.{
    Dispatcher,
    GoalLocalObservation,
    LeaseRenewal,
    Leases,
    WakeupObserve,
    WakeupRecord,
    WakeupWorker,
    Wakeups
  }

  alias Shoestring.Elves

  alias Shoestring.Harness.{
    CapacitySnapshot,
    CapacitySnapshotRecord,
    CheckpointRecord,
    ExecutionLease,
    ExecutionLeaseRecord,
    Observatory,
    Projector,
    RunRecord
  }

  alias Shoestring.Harness.Fake.Scenario
  alias Shoestring.Test.{ElvesHelpers, FixedClock, ManualClock}
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{ProjectorPosition, TrajectoryEvent}

  @now FixedClock.now()
  @scope "account:codex"
  @runner_opts [kill_grace_ms: 200, reap_timeout_ms: 2_000]
  @interval_ms 200

  # ----------------------------------------------------------------------------
  # Renewal twin
  # ----------------------------------------------------------------------------

  describe "lease renewal on an Observatory-owned reading" do
    test "LOCK: renews, and the goal's projector is not wedged" do
      %{goal: goal, grant_id: grant_id} = granted_lease()
      ledger = ingest!(eligible_snapshot(@now))

      assert {:ok, %{outcome: :renewed}} = renew(goal, grant_id, ledger)

      assert_projector_healthy(goal.id)
      assert Repo.get!(ExecutionLeaseRecord, grant_id).status == "renewed"
    end

    test "LOCK: a refused renewal expires cleanly, and the projector is not wedged" do
      %{goal: goal, grant_id: grant_id} = granted_lease()
      ledger = ingest!(breached_snapshot(@now))

      assert {:ok, %{outcome: :expired, events: [expired, required]}} =
               renew(goal, grant_id, ledger)

      assert expired.type == "lease.expired"
      assert required.type == "lease.checkpoint_required"

      assert_projector_healthy(goal.id)
      assert Repo.get!(ExecutionLeaseRecord, grant_id).status == "checkpoint_required"
    end

    test "LOCK: the lease chains to the goal's own observation, with ledger provenance" do
      %{goal: goal, grant_id: grant_id} = granted_lease()
      ledger = ingest!(eligible_snapshot(@now))

      local_id =
        GoalLocalObservation.snapshot_id("lease-renewal", goal.id, grant_id, ledger.snapshot_id)

      assert {:ok, %{admitted_snapshot_id: ^local_id, decision: decision}} =
               renew(goal, grant_id, ledger)

      assert decision.observation["snapshot_id"] == local_id
      assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

      assert Repo.get!(ExecutionLeaseRecord, grant_id).admitted_snapshot_id == local_id
      assert Repo.get!(CapacitySnapshotRecord, local_id).goal_id == goal.id

      [event] = renewal_snapshot_events(goal.id)
      assert event.payload["snapshot_id"] == local_id

      assert event.payload["extensions"]["cobbler.lease-renewal:observed_snapshot_id"] ==
               ledger.snapshot_id

      # The reading itself is carried unchanged.
      assert event.payload["capacity_state"] == "observed"
      assert event.payload["scope"] == @scope
      assert event.payload["source"]["provider_id"] == "codex"

      assert_ledger_row_intact(ledger)
    end

    test "LOCK: a retried renewal on the same reading replays: one observation, one decision" do
      %{goal: goal, grant_id: grant_id} = granted_lease()
      ledger = ingest!(eligible_snapshot(@now))

      assert {:ok, %{outcome: :renewed, admitted_snapshot_id: local_id}} =
               renew(goal, grant_id, ledger)

      snapshots = renewal_snapshot_events(goal.id)
      decisions = renewal_decision_events(goal.id)
      renewed = event_count(goal.id, ["lease.renewed"])

      # A crash-retry at the same boundary re-observes the same reading.
      assert {:ok, %{outcome: :renewed, admitted_snapshot_id: ^local_id}} =
               renew(goal, grant_id, ledger)

      assert renewal_snapshot_events(goal.id) == snapshots
      assert renewal_decision_events(goal.id) == decisions
      assert event_count(goal.id, ["lease.renewed"]) == renewed
      assert [_one] = snapshots
      assert [_one] = decisions
      assert_projector_healthy(goal.id)
    end

    test "LOCK: two goals renewing on the SAME ledger reading each own their observation" do
      ledger = ingest!(eligible_snapshot(@now))

      # Task claims are exclusive across goals, so the two leases are
      # sequential: renew under the first goal, release, then the second.
      first = granted_lease()

      assert {:ok, %{outcome: :renewed, admitted_snapshot_id: first_id}} =
               renew(first.goal, first.grant_id, ledger)

      {:ok, %{command: released}} =
        Shoestring.Cobbler.Commands.submit(first.goal.id, release_command())

      assert released.status == "resolved"

      second = granted_lease()

      assert {:ok, %{outcome: :renewed, admitted_snapshot_id: second_id}} =
               renew(second.goal, second.grant_id, ledger)

      refute first_id == second_id
      assert Repo.get!(CapacitySnapshotRecord, first_id).goal_id == first.goal.id
      assert Repo.get!(CapacitySnapshotRecord, second_id).goal_id == second.goal.id
      assert_projector_healthy(first.goal.id)
      assert_projector_healthy(second.goal.id)
      assert_ledger_row_intact(ledger)
    end
  end

  # ----------------------------------------------------------------------------
  # Wake twin, through the production-configured worker
  # ----------------------------------------------------------------------------

  describe "a wake through the :prod WakeupObserve MFA" do
    setup do
      ManualClock.set(@now)

      previous = %{
        clock: Application.get_env(:shoestring, :dispatch_clock),
        observe: Application.get_env(:shoestring, :wakeup_observe)
      }

      Application.put_env(:shoestring, :dispatch_clock, ManualClock)
      # Verbatim from the `:prod` block of `config/runtime.exs`.
      Application.put_env(:shoestring, :wakeup_observe, {WakeupObserve, :observe, []})

      on_exit(fn ->
        restore(:dispatch_clock, previous.clock)
        restore(:wakeup_observe, previous.observe)
      end)

      :ok
    end

    test "LOCK: an admitted wake renews and dispatches, and the projector is not wedged" do
      %{goal: goal, run: run, grant_id: grant_id} = sleeping_lease()
      ledger = ingest!(eligible_snapshot(@now))
      wakeup = schedule_wake!(goal, run, "cmd-twin-wake-admit")

      assert :ok = WakeupWorker.perform(worker_job(wakeup))

      assert Repo.get!(WakeupRecord, wakeup.id).status == "woken"
      assert_projector_healthy(goal.id)

      local_id =
        GoalLocalObservation.snapshot_id("wakeup", goal.id, wakeup.id, ledger.snapshot_id)

      assert Repo.get!(ExecutionLeaseRecord, grant_id).admitted_snapshot_id == local_id
      assert Repo.get!(CapacitySnapshotRecord, local_id).goal_id == goal.id

      [event] = wake_snapshot_events(goal.id)

      assert event.payload["extensions"]["cobbler.wakeup:observed_snapshot_id"] ==
               ledger.snapshot_id

      assert_ledger_row_intact(ledger)
    end

    test "LOCK: a refused reading defers the wake, and the projector is not wedged" do
      %{goal: goal, run: run, grant_id: grant_id} = sleeping_lease()
      ingest!(breached_snapshot(@now))
      wakeup = schedule_wake!(goal, run, "cmd-twin-wake-defer")
      dispatches = Repo.aggregate(Shoestring.Harness.DispatchRecord, :count, :dispatch_id)

      assert :ok = WakeupWorker.perform(worker_job(wakeup))

      # The defer branch settles this wake and re-sleeps: the run stays
      # suspended, the old allowance is closed, and nothing is dispatched.
      assert Repo.get!(WakeupRecord, wakeup.id).status == "woken"
      assert [decision] = wake_decision_events(goal.id)
      assert decision.payload["result"] == "defer_until"
      assert_projector_healthy(goal.id)
      assert Repo.get!(RunRecord, run.id).status == "suspended"
      assert Repo.get!(ExecutionLeaseRecord, grant_id).status == "checkpoint_required"

      assert Repo.aggregate(Shoestring.Harness.DispatchRecord, :count, :dispatch_id) ==
               dispatches
    end

    test "LOCK: performing the same wake twice converges on one observation and one decision" do
      %{goal: goal, run: run} = sleeping_lease()
      ingest!(eligible_snapshot(@now))
      wakeup = schedule_wake!(goal, run, "cmd-twin-wake-twice")

      assert :ok = WakeupWorker.perform(worker_job(wakeup))
      assert :ok = WakeupWorker.perform(worker_job(wakeup))

      assert [_one] = wake_snapshot_events(goal.id)
      assert [_one] = wake_decision_events(goal.id)
      assert_projector_healthy(goal.id)
    end
  end

  # ----------------------------------------------------------------------------
  # The Elf, end to end: the exact #82 shape
  # ----------------------------------------------------------------------------

  describe "an Elf whose renewal probe returns an Observatory-owned reading" do
    setup do
      sup = start_supervised!({Shoestring.Elves.Supervisor, name: nil})
      %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()
      {:ok, sup: sup, goal: goal, task: task}
    end

    test "LOCK: renews at the boundary, and the terminal checkpoint and run.completed project",
         %{sup: sup, goal: goal, task: task} do
      ledger = ingest!(eligible_snapshot(@now))
      admitted_id = Ecto.UUID.generate()
      FakeHelpers.append_capacity_snapshot(goal, admitted_id)
      assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

      # The probe hands the Elf the ledger's own snapshot, id and all — what
      # `CodexAppServer.probe/1` returns in production.
      scenario = %Scenario{
        name: :observatory_renewal,
        capacity: ledger,
        start_error: nil,
        resume_error: nil,
        provider_session_id: "fake-session-observatory-renewal",
        events: [
          Scenario.lifecycle_event(source_event_id: "evt-life"),
          Scenario.output_event("one", source_event_id: "evt-out-1"),
          Scenario.output_event("two", source_event_id: "evt-out-2"),
          Scenario.output_event("three", source_event_id: "evt-out-3"),
          Scenario.result_event("completed", source_event_id: "evt-done")
        ],
        delivery_modifier: :none
      }

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

      assert {:ok, run_id} =
               ElvesHelpers.wait_until(fn ->
                 ElvesHelpers.run_id_for_dispatch(request.dispatch_id)
               end)

      assert {:ok, _pgid} =
               ElvesHelpers.wait_until(fn -> ElvesHelpers.recorded_pgid(goal.id, run_id) end)

      on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

      # checkpoint_cadence 1 — what `/runs/new` proposes — so renewal is due
      # after the first response, exactly as in the live run.
      grant_id = grant_for_run!(goal, run_id, admitted_id, checkpoint_cadence: 1)

      assert_receive {:elf_terminal, ^run_id, %{class: :completed}}, 15_000

      # Renewal reached a decision and admitted (at base it failed at the
      # projector on every boundary and the Elf "worked on"). The final row
      # status is not asserted: a re-renewal on the SAME unchanged reading
      # replays its epoch keys by design, so the row may rest `renewal_due`.
      assert ElvesHelpers.count_events(goal.id, run_id, ["lease.renewed"]) >= 1
      assert ElvesHelpers.count_events(goal.id, run_id, ["lease.expired"]) == 0
      assert_projector_healthy(goal.id)

      assert Repo.get!(RunRecord, run_id).status == "completed"
      assert Repo.get!(ExecutionLeaseRecord, grant_id).status in ["renewed", "renewal_due"]

      # The run's canonical terminal checkpoint is a row — the thing
      # `run.handoff` validation needs (`handoff_checkpoint_not_found` live).
      terminal_checkpoint_id =
        Repo.one!(
          from event in TrajectoryEvent,
            where:
              event.goal_id == ^goal.id and event.run_id == ^run_id and
                event.type == "checkpoint.created",
            order_by: [desc: event.sequence],
            limit: 1,
            select: fragment("json_extract(?, '$.checkpoint_id')", event.payload)
        )

      assert %CheckpointRecord{run_id: ^run_id} =
               Repo.get(CheckpointRecord, terminal_checkpoint_id)

      assert_ledger_row_intact(ledger)
    end
  end

  # ----------------------------------------------------------------------------
  # Ownership is not relaxed
  # ----------------------------------------------------------------------------

  test "DOC: the projector still refuses a work goal re-appending a ledger-owned id" do
    goal = create_goal!()
    ledger = ingest!(eligible_snapshot(@now))

    {:ok, _event} =
      Trajectory.append(goal.id, %{
        "type" => "capacity.snapshot_observed",
        "schema_version" => 2,
        "actor" => "cobbler-test",
        "occurred_at" => @now,
        "payload" => Shoestring.Harness.EventPayload.capacity_snapshot(ledger, nil)
      })

    assert {:error,
            {:harness_projection_failed, 1, {:capacity_snapshot_not_owned, id}, _position}} =
             Projector.project(goal.id, clock: FixedClock)

    assert id == ledger.snapshot_id

    # The refused append did not take the row over.
    assert Repo.get!(CapacitySnapshotRecord, ledger.snapshot_id).goal_id ==
             Observatory.observatory_goal_id()
  end

  # ----------------------------------------------------------------------------
  # Fixtures
  # ----------------------------------------------------------------------------

  defp renew(goal, grant_id, observed) do
    LeaseRenewal.maybe_renew(goal.id, grant_id,
      now: @now,
      stop: :already_requested,
      boundary: :item_completed,
      clock: FixedClock,
      observe: fn -> {:ok, observed} end
    )
  end

  defp granted_lease do
    goal = create_goal!()
    task = insert_task!(goal)
    snapshot_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, snapshot_id)
    admission = append_admission_event!(goal.id, grant_payload(snapshot_id, 100))

    command =
      claim_command(admission, command_id: "cmd-twin-#{System.unique_integer([:positive])}")

    assert {:ok, leased} =
             Dispatcher.claim_and_gate(goal.id, command,
               now: @now,
               grant_lease: [task_id: task.id, clock: FixedClock, now: FixedClock.now()]
             )

    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    %{goal: goal, task: task, run: leased.run, grant_id: leased.grant_id}
  end

  defp sleeping_lease do
    %{goal: goal, run: run} = lease = granted_lease()

    for type <- ["run.starting", "run.running", "run.pausing", "run.suspended"] do
      {:ok, _} =
        Trajectory.append(
          goal.id,
          %{
            "type" => type,
            "schema_version" => 1,
            "actor" => "cobbler-test",
            "occurred_at" => @now,
            "payload" => %{"run_id" => run.id}
          },
          trusted: [run_id: run.id]
        )
    end

    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)
    assert Repo.get!(RunRecord, run.id).status == "suspended"
    lease
  end

  defp schedule_wake!(goal, run, command_id) do
    now = ManualClock.now()

    assert {:ok, %{wakeup: wakeup, outcome: :recorded}} =
             Wakeups.schedule(goal.id,
               command_id: command_id,
               wake_at: now,
               now: now,
               clock: ManualClock,
               run_id: run.id
             )

    wakeup
  end

  defp worker_job(wakeup) do
    %Job{
      args: %{
        "wakeup_id" => wakeup.id,
        "goal_id" => wakeup.goal_id,
        "idempotency_key" => wakeup.idempotency_key
      }
    }
  end

  defp grant_for_run!(goal, run_id, admitted_snapshot_id, opts) do
    decision_id = Ecto.UUID.generate()
    grant_id = Ecto.UUID.generate()
    cadence = Keyword.fetch!(opts, :checkpoint_cadence)
    deadline = DateTime.add(FixedClock.now(), 3_600, :second)

    admission =
      append_admission_event!(
        goal.id,
        grant_payload(admitted_snapshot_id, cadence)
        |> Map.put("decision_id", decision_id)
      )

    {:ok, lease} =
      ExecutionLease.new(%{
        version: 1,
        grant_id: grant_id,
        run_id: run_id,
        admitted_snapshot_id: admitted_snapshot_id,
        reserves: %{response: 1, tool: 1},
        response_budget: 100,
        tool_budget: 100,
        deadline: deadline,
        checkpoint_cadence: cadence,
        renewal_state: :none,
        extensions: %{
          "cobbler.lease:admission_decision_id" => decision_id,
          "cobbler.lease:admission_event_id" => admission.id,
          "cobbler.lease:candidate" => "codex/codex_app_server",
          "cobbler.lease:scope" => @scope
        }
      })

    assert {:ok, %{grant_id: ^grant_id}} = Leases.grant(goal.id, lease)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)
    grant_id
  end

  defp insert_task!(goal) do
    %Shoestring.Trajectory.Task{}
    |> Shoestring.Trajectory.Task.changeset(%{"title" => "Observatory twin task"})
    |> Ecto.Changeset.put_change(:goal_id, goal.id)
    |> Repo.insert!()
  end

  defp grant_payload(snapshot_id, cadence) do
    admission_payload()
    |> Map.merge(%{
      "result" => "admit",
      "reason_code" => "automatic_admission_eligible",
      "explanation" => "Observatory twin test admission",
      "observation" => %{
        "snapshot_id" => snapshot_id,
        "confidence" => "high",
        "freshness" => "fresh"
      },
      "proposed_bounds" => %{
        "response_budget" => 100,
        "tool_budget" => 100,
        "deadline" => DateTime.to_iso8601(DateTime.add(@now, 3_600, :second)),
        "checkpoint_cadence" => cadence,
        "reserves" => %{"response" => 1, "tool" => 1}
      }
    })
  end

  # ----------------------------------------------------------------------------
  # Observatory ledger
  # ----------------------------------------------------------------------------

  defp ingest!(%CapacitySnapshot{} = snapshot) do
    assert {:ok, :persisted, persisted} = Observatory.ingest(snapshot, now: @now)

    assert Repo.get!(CapacitySnapshotRecord, persisted.snapshot_id).goal_id ==
             Observatory.observatory_goal_id()

    persisted
  end

  # The Observatory's own row is untouched: same owner, same state, and its
  # snapshot event is still the Observatory goal's.
  defp assert_ledger_row_intact(%CapacitySnapshot{snapshot_id: id} = ledger) do
    row = Repo.get!(CapacitySnapshotRecord, id)
    assert row.goal_id == Observatory.observatory_goal_id()
    assert row.capacity_state == Atom.to_string(ledger.capacity_state)

    owners =
      Repo.all(
        from event in TrajectoryEvent,
          where:
            event.type == "capacity.snapshot_observed" and
              fragment("json_extract(?, '$.snapshot_id')", event.payload) == ^id,
          select: event.goal_id
      )

    assert owners == [Observatory.observatory_goal_id()]
  end

  defp assert_projector_healthy(goal_id) do
    assert {:ok, _} = Projector.project(goal_id, clock: FixedClock)
    position = Repo.get_by!(ProjectorPosition, goal_id: goal_id, projector: "harness")
    assert position.status != "failed"
    assert is_nil(position.error_detail)

    last =
      Repo.one(from e in TrajectoryEvent, where: e.goal_id == ^goal_id, select: max(e.sequence))

    assert position.last_sequence == last
  end

  defp eligible_snapshot(now), do: codex_snapshot(now, 20.0)
  defp breached_snapshot(now), do: codex_snapshot(now, 95.0)

  defp codex_snapshot(now, used_percent) do
    {:ok, snapshot} =
      CapacitySnapshot.new(
        %{
          version: 2,
          snapshot_id: Ecto.UUID.generate(),
          capacity_state: :observed,
          windows: [
            %{kind: "five_hour", state: :observed, used_percent: used_percent, reset_at: nil},
            %{kind: "weekly", state: :observed, used_percent: 30.0, reset_at: nil}
          ],
          observed_at: now,
          freshness: %{max_age_seconds: 300},
          source: %{
            adapter_id: "codex_app_server",
            provider_id: "codex",
            invocation_mode: "app_server",
            event: :explicit_read
          },
          scope: @scope,
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

  # ----------------------------------------------------------------------------
  # Reads
  # ----------------------------------------------------------------------------

  defp renewal_snapshot_events(goal_id),
    do: keyed(goal_id, "capacity.snapshot_observed", "lease-renewal-snapshot:%")

  defp renewal_decision_events(goal_id),
    do: keyed(goal_id, "admission.decided", "lease-renewal-decision:%")

  defp wake_snapshot_events(goal_id),
    do: keyed(goal_id, "capacity.snapshot_observed", "wakeup-snapshot:%")

  defp wake_decision_events(goal_id), do: keyed(goal_id, "admission.decided", "wakeup-decision:%")

  defp keyed(goal_id, type, pattern) do
    Repo.all(
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^goal_id and event.type == ^type and
            like(event.idempotency_key, ^pattern),
        order_by: [asc: event.sequence]
    )
  end

  defp restore(key, nil), do: Application.delete_env(:shoestring, key)
  defp restore(key, value), do: Application.put_env(:shoestring, key, value)
end
