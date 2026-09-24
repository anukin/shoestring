defmodule Shoestring.Cobbler.AdmissionRecoveryTest do
  @moduledoc """
  Hermetic DataCase regressions for admission and wake/dispatch recovery
  across the crash windows the durable pipeline leaves open.

  Every test here re-drives a real code path; the only simulation is a
  wakeup row flipped back to `due`, which is precisely the "effects
  committed, `woken` mark not yet written" crash state the module documents
  (`Wakeups.perform_wakeup/2` runs without an enclosing transaction, so a
  crash after a branch effect leaves exactly this state).

  No provider CLI, no network, no live quota: `Shoestring.Harness.Fake`
  identity and in-memory snapshots only.

  Locking note (standing contract). Verified against base
  `6fd0ecd2e6929fcc7f393ac6e3f7166fc7a6b57d` in a separate checkout; each
  test's own comment records whether it FAILS on base for a behavioural
  reason (a true regression lock) or PASSES on base (a preservation test
  that documents behaviour rather than locking a fix).
  """
  use Shoestring.DataCase, async: false

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers

  alias Oban.Job

  alias Shoestring.Cobbler.{
    Command,
    Commands,
    Dispatcher,
    GoalLocalObservation,
    Leases,
    Wakeups,
    WakeupRecord
  }

  alias Shoestring.Harness.{
    CapacitySnapshot,
    DispatchRecord,
    ExecutionLeaseRecord,
    Projector,
    RunRecord
  }

  alias Shoestring.Test.ManualClock
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.TrajectoryEvent

  @t0 ~U[2026-09-07 12:00:00.000000Z]

  # ----------------------------------------------------------------------------
  # Wake retry: decision freshness, verdict agreement, continuation neutralizing
  # ----------------------------------------------------------------------------

  describe "wake retry across the enqueue crash window" do
    setup :suspended_run_holding_a_claim

    # REGRESSION LOCK (fails on base). On base `record_decision/8` keyed
    # idempotency on (wakeup, snapshot) alone, so the retry replayed the
    # ADMIT recorded before the crash even though the fresh evaluation of
    # that same, now-stale reading demands confirmation. The retry
    # re-admitted, and the continuation dispatch enqueued by the first
    # attempt stayed `requested` — executable, unadmitted work behind an
    # operator surface reporting "waiting for approval".
    test "a retry that now requires confirmation neutralizes the superseded continuation",
         %{goal: goal, run: run} do
      snapshot = eligible_snapshot!()
      wakeup = schedule_wake!(goal, run, "cmd-recovery-confirm")

      assert {:ok, %{branch: :admitted} = admitted} =
               perform(wakeup, snapshot, ManualClock.now())

      assert admitted.dispatch.outcome == :dispatched
      assert %DispatchRecord{status: "requested"} = Repo.get!(DispatchRecord, wakeup.id)
      continuation_run_id = admitted.dispatch.run_id

      crash_before_woken_mark!(wakeup)

      # The same reading, re-observed after its freshness window lapsed.
      ManualClock.advance(3_600, :second)

      assert {:ok, summary} = perform(wakeup, snapshot, ManualClock.now())

      # The fresh verdict governs ...
      assert summary.branch == :require_confirmation
      assert summary.lifecycle == :sleeping

      # ... explicit approval is still required, not granted by the sweep ...
      assert summary.operator_action == :confirmation_required

      # ... the superseded continuation can no longer be executed ...
      assert %DispatchRecord{status: "effect_deferred"} = Repo.get!(DispatchRecord, wakeup.id)

      # ... and nothing was duplicated: still exactly one continuation run.
      assert continuation_run_ids(wakeup) == [continuation_run_id]
      assert Repo.get!(WakeupRecord, wakeup.id).status == "woken"
    end

    # TWIN (fails on base for the same reason as above). The neutralizing
    # flip is bookkeeping for work that has not started. An effect already
    # under way cannot be un-executed, so a dispatch past `requested` is
    # left exactly as it is — the fresh refusal decision is the audit trail.
    test "a continuation whose effect already began is not rewritten by the confirmation retry",
         %{goal: goal, run: run} do
      snapshot = eligible_snapshot!()
      wakeup = schedule_wake!(goal, run, "cmd-recovery-confirm-started")

      assert {:ok, %{branch: :admitted}} = perform(wakeup, snapshot, ManualClock.now())

      Repo.get!(DispatchRecord, wakeup.id)
      |> DispatchRecord.status_changeset("effect_started", ManualClock.now())
      |> Repo.update!()

      crash_before_woken_mark!(wakeup)
      ManualClock.advance(3_600, :second)

      assert {:ok, %{branch: :require_confirmation}} =
               perform(wakeup, snapshot, ManualClock.now())

      assert %DispatchRecord{status: "effect_started"} = Repo.get!(DispatchRecord, wakeup.id)
    end

    # REGRESSION LOCK (fails on base). The stale-snapshot-id reuse defect in
    # isolation: an adapter that reuses a snapshot id (as the Codex adapter
    # did for every unmonitored probe) made the recorded admit permanently
    # replayable under that id. The guard is BOTH freshness and verdict
    # agreement, so this asserts the decision ledger directly rather than
    # only the branch it produced.
    test "a stale snapshot id mints a fresh decision instead of replaying the admit",
         %{goal: goal, run: run} do
      snapshot = eligible_snapshot!()
      wakeup = schedule_wake!(goal, run, "cmd-recovery-stale-id")

      assert {:ok, %{decision_id: first_decision_id, branch: :admitted}} =
               perform(wakeup, snapshot, ManualClock.now())

      crash_before_woken_mark!(wakeup)
      ManualClock.advance(3_600, :second)

      assert {:ok, %{decision_id: second_decision_id, branch: :require_confirmation}} =
               perform(wakeup, snapshot, ManualClock.now())

      refute second_decision_id == first_decision_id

      # Both decisions are durably recorded under this wakeup and this
      # snapshot: the fresh refusal is appended, it does not overwrite or
      # erase the admit it supersedes.
      assert [
               %{"result" => "admit", "decision_id" => ^first_decision_id},
               %{
                 "result" => "require_confirmation",
                 "decision_id" => ^second_decision_id
               }
             ] = wake_decision_payloads(goal, wakeup, snapshot)
    end

    # PRESERVATION, stated precisely. The converse direction of the guard
    # above, and the reason it cannot simply mint a decision per attempt: an
    # immediate retry re-observing the same reading inside its freshness
    # window, reaching the same verdict, must converge on the first decision
    # rather than fan out decisions — and therefore runs. On base this
    # already held, through the writer's idempotency-key collapse; it now
    # holds through the explicit replay guard, and this asserts the new
    # guard did not regress it.
    #
    # Honest note: this test DOES fail when run against base, but NOT for a
    # behavioural reason — `wake_decision_payloads/3` filters on the new
    # decision-id-suffixed key format, which base never writes, so the query
    # returns `[]`. The substantive claims (one decision id, one
    # continuation run, two dispatch records) hold on base as well. Treat
    # this as documentation, not as a regression lock.
    test "an immediate retry on the same fresh reading replays one decision and one run",
         %{goal: goal, run: run} do
      snapshot = eligible_snapshot!()
      wakeup = schedule_wake!(goal, run, "cmd-recovery-converge")

      assert {:ok, %{decision_id: decision_id, branch: :admitted} = first} =
               perform(wakeup, snapshot, ManualClock.now())

      crash_before_woken_mark!(wakeup)

      assert {:ok, %{decision_id: ^decision_id, branch: :admitted} = second} =
               perform(wakeup, snapshot, ManualClock.now())

      assert [%{"decision_id" => ^decision_id}] = wake_decision_payloads(goal, wakeup, snapshot)
      assert second.dispatch.run_id == first.dispatch.run_id
      assert length(continuation_run_ids(wakeup)) == 1
      assert Repo.aggregate(DispatchRecord, :count, :dispatch_id) == 2
    end

    # REGRESSION LOCK (fails on base). A retry that re-observes FRESH
    # capacity legitimately mints a new decision, and continuation
    # `decision_refs` are projected from the goal's decision history, so the
    # rebuilt request no longer byte-matches the run the first attempt
    # persisted. On base `Runs.request/3` reported `dispatch_id_conflict`
    # and the wake failed with `{:wakeup_run_failed, ...}` — stranded, and
    # stranded again on every subsequent retry, because the mismatch is
    # permanent.
    test "a retry on a newer reading recovers its own run instead of conflicting",
         %{goal: goal, run: run} do
      wakeup = schedule_wake!(goal, run, "cmd-recovery-conflict")

      assert {:ok, %{branch: :admitted} = first} =
               perform(wakeup, eligible_snapshot!(), ManualClock.now())

      crash_before_woken_mark!(wakeup)
      ManualClock.advance(60, :second)

      assert {:ok, %{branch: :admitted, decision_id: fresh_decision_id} = second} =
               perform(wakeup, eligible_snapshot!(), ManualClock.now())

      # At most one: recovery re-adopts the run bound to this wakeup's
      # dispatch id, it never creates a second one.
      assert second.dispatch.run_id == first.dispatch.run_id
      assert continuation_run_ids(wakeup) == [first.dispatch.run_id]
      assert Repo.aggregate(DispatchRecord, :count, :dispatch_id) == 2
      assert Repo.aggregate(from(job in Job, where: job.queue == "dispatch"), :count, :id) == 2

      # The re-adopted run carries the FRESH decision, not the superseded
      # one: `Continuation.validate_resume/3` refuses a resume whose
      # decision refs are superseded, so stale refs would hand the Elf a run
      # it must refuse.
      continuation = Repo.get!(RunRecord, second.dispatch.run_id)
      assert fresh_decision_id in continuation.continuation["decision_refs"]
      assert goal.id == continuation.goal_id
    end

    # TWIN (fails on base, at a different assertion). Recovery is narrow by
    # construction: a row bound to this dispatch id that is NOT this wake's
    # own prior attempt is a genuine conflict and must still error rather
    # than being silently adopted.
    test "a genuinely different run bound to the dispatch id is still a conflict",
         %{goal: goal, run: run} do
      wakeup = schedule_wake!(goal, run, "cmd-recovery-genuine-conflict")

      assert {:ok, %{branch: :admitted} = first} =
               perform(wakeup, eligible_snapshot!(), ManualClock.now())

      # A different prompt is a different request identity, not a
      # continuation whose decision refs merely moved on.
      Repo.get!(RunRecord, first.dispatch.run_id)
      |> Ecto.Changeset.change(%{prompt: "an entirely different unit of work"})
      |> Repo.update!()

      crash_before_woken_mark!(wakeup)
      ManualClock.advance(60, :second)

      assert {:error, {:wakeup_run_failed, {:conflict, :prompt}}} =
               perform(wakeup, eligible_snapshot!(), ManualClock.now())

      assert Repo.get!(WakeupRecord, wakeup.id).status == "due"
      assert continuation_run_ids(wakeup) == [first.dispatch.run_id]
    end
  end

  # ----------------------------------------------------------------------------
  # Grant-then-enqueue crash window
  # ----------------------------------------------------------------------------

  describe "restart after a grant that never reached enqueue" do
    setup :goal_and_task

    # REGRESSION LOCK (fails on base). `Leases.issue_for_claim/6` persists
    # the run row and the grant; `Dispatcher` enqueues delivery only
    # afterwards. A crash in between leaves a granted, projected,
    # `requested` run with no dispatch row. On base the replay branch
    # reported `run: nil` ("zero new rows"), so `dispatch_granted/2` skipped
    # enqueue and every retry skipped it again — the grant was permanently
    # stranded. The repair query could not rescue it either: it excluded
    # every run whose projection had advanced, which is exactly this one.
    test "the retry delivers the stranded grant exactly once", %{goal: goal, task: task} do
      %{row: row, command: command, claim: claim, attrs: attrs} = claimed_command(goal)

      # The crash state, produced by driving the real grant path and simply
      # not reaching the enqueue that follows it in `Dispatcher`.
      assert {:ok, %{run: %RunRecord{} = granted_run, grant_id: grant_id}} =
               Leases.issue_for_claim(goal.id, row, command, claim, :recorded,
                 task_id: task.id,
                 clock: ManualClock,
                 now: ManualClock.now()
               )

      assert {:ok, _} = Projector.project(goal.id, clock: ManualClock)
      assert %RunRecord{status: "requested"} = reloaded = Repo.get!(RunRecord, granted_run.id)
      assert reloaded.projection_sequence > 0
      refute Repo.get(DispatchRecord, reloaded.dispatch_id)
      assert %ExecutionLeaseRecord{} = Repo.get!(ExecutionLeaseRecord, grant_id)

      # The operator retries the identical command.
      assert {:ok, retry} =
               Dispatcher.claim_and_gate(goal.id, attrs,
                 now: ManualClock.now(),
                 grant_lease: [task_id: task.id, clock: ManualClock, now: ManualClock.now()]
               )

      assert retry.lease_outcome == :replayed
      assert retry.grant_id == grant_id
      assert %DispatchRecord{} = retry.dispatch
      assert %Job{} = retry.job
      assert retry.dispatch.run_id == granted_run.id

      # Zero new runs and zero new grants: the replay delivered the run it
      # already had.
      assert Repo.aggregate(RunRecord, :count, :id) == 1
      assert Repo.aggregate(ExecutionLeaseRecord, :count, :id) == 1
      assert Repo.aggregate(DispatchRecord, :count, :dispatch_id) == 1
      assert Repo.aggregate(from(job in Job, where: job.queue == "dispatch"), :count, :id) == 1

      # And a third attempt still adds nothing.
      assert {:ok, again} =
               Dispatcher.claim_and_gate(goal.id, attrs,
                 now: ManualClock.now(),
                 grant_lease: [task_id: task.id, clock: ManualClock, now: ManualClock.now()]
               )

      assert again.lease_outcome == :replayed
      assert Repo.aggregate(DispatchRecord, :count, :dispatch_id) == 1
      assert Repo.aggregate(from(job in Job, where: job.queue == "dispatch"), :count, :id) == 1
    end

    # TWIN (passes on base — preservation). The other half of the same
    # ruling: a grant whose delivery ALREADY exists must keep reporting
    # `run: nil` so the replay stays a zero-row replay. Widening recovery
    # must not turn every replay into a re-enqueue, and an execution already
    # under way must never be treated as absent.
    test "a grant that already has delivery stays a zero-row replay", %{goal: goal, task: task} do
      %{attrs: attrs} = claimed_command(goal)

      grant_opts = [task_id: task.id, clock: ManualClock, now: ManualClock.now()]

      assert {:ok, first} =
               Dispatcher.claim_and_gate(goal.id, attrs,
                 now: ManualClock.now(),
                 grant_lease: grant_opts
               )

      assert first.lease_outcome == :recorded
      assert %DispatchRecord{} = first.dispatch

      assert {:ok, replay} =
               Dispatcher.claim_and_gate(goal.id, attrs,
                 now: ManualClock.now(),
                 grant_lease: grant_opts
               )

      assert replay.lease_outcome == :replayed
      assert replay.run == nil
      assert replay.dispatch == nil
      assert replay.job == nil
      assert Repo.aggregate(DispatchRecord, :count, :dispatch_id) == 1
      assert Repo.aggregate(from(job in Job, where: job.queue == "dispatch"), :count, :id) == 1
    end
  end

  # ----------------------------------------------------------------------------
  # Setups
  # ----------------------------------------------------------------------------

  defp goal_and_task(_context) do
    ManualClock.set(@t0)
    goal = create_goal!()
    {:ok, goal: goal, task: insert_task!(goal)}
  end

  # Mirrors the `WakeReobserveTest` arrangement: a claimed, granted, then
  # suspended run with a live lease, which is the only state a wake
  # continuation can be dispatched from.
  defp suspended_run_holding_a_claim(_context) do
    ManualClock.set(@t0)
    goal = create_goal!()
    task = insert_task!(goal)
    snapshot_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, snapshot_id)

    admission = append_admission_event!(goal.id, grant_payload(snapshot_id))

    assert {:ok, leased} =
             Dispatcher.claim_and_gate(goal.id, claim_command(admission, command_id: "cmd-setup"),
               now: @t0,
               grant_lease: [task_id: task.id, clock: ManualClock, now: @t0]
             )

    assert {:ok, _} = Projector.project(goal.id, clock: ManualClock)
    suspend_run!(goal, leased.run)
    assert {:ok, _} = Projector.project(goal.id, clock: ManualClock)
    assert Repo.get!(RunRecord, leased.run.id).status == "suspended"

    {:ok, goal: goal, task: task, run: leased.run, grant_id: leased.grant_id}
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  defp perform(wakeup, snapshot, now) do
    Wakeups.perform_wakeup(wakeup.id,
      now: now,
      clock: ManualClock,
      observe: fn -> {:ok, snapshot} end
    )
  end

  # `perform_wakeup/2` marks the row `woken` only after its branch writes
  # commit and runs under no enclosing transaction, so a crash in that final
  # gap leaves committed effects behind a still-actionable row. That is the
  # state under test.
  defp crash_before_woken_mark!(wakeup) do
    Repo.get!(WakeupRecord, wakeup.id)
    |> Ecto.Changeset.change(%{status: "due"})
    |> Repo.update!()
  end

  defp continuation_run_ids(wakeup) do
    Repo.all(
      from run in RunRecord,
        where: run.dispatch_id == ^wakeup.id,
        order_by: [asc: run.inserted_at, asc: run.id],
        select: run.id
    )
  end

  defp wake_decision_payloads(goal, wakeup, snapshot) do
    # Decisions are keyed on the wake's goal-local observation of the reading.
    local_id =
      GoalLocalObservation.snapshot_id("wakeup", goal.id, wakeup.id, snapshot.snapshot_id)

    prefix = "wakeup-decision:#{wakeup.id}:#{local_id}:"

    Repo.all(
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^goal.id and event.type == "admission.decided" and
            like(event.idempotency_key, ^"#{prefix}%"),
        order_by: [asc: event.sequence],
        select: event.payload
    )
    |> Enum.map(&Map.take(&1, ["result", "decision_id"]))
  end

  defp claimed_command(goal) do
    # The lease projection binds a grant to the admitted snapshot row, so the
    # observation the decision cites has to exist in the ledger.
    snapshot_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, snapshot_id)
    admission = append_admission_event!(goal.id, grant_payload(snapshot_id))
    attrs = claim_command(admission, command_id: "cmd-stranded-grant")

    assert {:ok, %{command: row, outcome: :recorded}} =
             Commands.submit(goal.id, attrs, now: ManualClock.now())

    assert {:ok, command} =
             Command.new(%{
               "version" => row.version,
               "command_id" => row.command_id,
               "type" => row.type,
               "payload" => row.payload
             })

    %{row: row, command: command, claim: Commands.active_claim([]), attrs: attrs}
  end

  defp insert_task!(goal) do
    %Shoestring.Trajectory.Task{}
    |> Shoestring.Trajectory.Task.changeset(%{"title" => "Recovery task"})
    |> Ecto.Changeset.put_change(:goal_id, goal.id)
    |> Repo.insert!()
  end

  defp grant_payload(snapshot_id) do
    admission_payload()
    |> Map.merge(%{
      "decision_id" => Ecto.UUID.generate(),
      "result" => "admit",
      "reason_code" => "automatic_admission_eligible",
      "explanation" => "Recovery matrix setup grant",
      "observation" => %{
        "snapshot_id" => snapshot_id,
        "confidence" => "high",
        "freshness" => "fresh"
      },
      "proposed_bounds" => %{
        "response_budget" => 10,
        "tool_budget" => 25,
        "deadline" => DateTime.to_iso8601(DateTime.add(@t0, 300, :second)),
        "checkpoint_cadence" => 1,
        "reserves" => %{"response" => 1, "tool" => 1}
      }
    })
  end

  defp suspend_run!(goal, run) do
    for type <- ["run.starting", "run.running", "run.pausing", "run.suspended"] do
      {:ok, _} =
        Trajectory.append(
          goal.id,
          %{
            "type" => type,
            "schema_version" => 1,
            "actor" => "cobbler-test",
            "occurred_at" => ManualClock.now(),
            "payload" => %{"run_id" => run.id}
          },
          trusted: [run_id: run.id]
        )
    end

    :ok
  end

  defp schedule_wake!(goal, run, command_id) do
    now = ManualClock.now()

    assert {:ok, %{wakeup: wakeup, outcome: :recorded}} =
             Wakeups.schedule(goal.id,
               command_id: command_id,
               run_id: run.id,
               wake_at: now,
               now: now,
               clock: ManualClock
             )

    wakeup
  end

  defp eligible_snapshot! do
    now = ManualClock.now()
    reset_at = DateTime.add(now, 7_200, :second)

    attrs = %{
      version: 2,
      snapshot_id: Ecto.UUID.generate(),
      capacity_state: :observed,
      windows: [
        %{kind: "five_hour", state: :observed, used_percent: 10.0, reset_at: reset_at},
        %{kind: "weekly", state: :observed, used_percent: 12.0, reset_at: reset_at}
      ],
      observed_at: now,
      freshness: %{max_age_seconds: 300},
      source: %{
        adapter_id: "shoestring.harness.fake",
        provider_id: "codex",
        invocation_mode: "headless",
        event: :explicit_read
      },
      scope: "account:codex",
      confidence: :high,
      support_tier: :proactive,
      compatibility_state: :compatible,
      reason: nil,
      extensions: %{}
    }

    {:ok, snapshot} = CapacitySnapshot.new(attrs, now: now)
    snapshot
  end
end
