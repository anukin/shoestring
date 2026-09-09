defmodule Shoestring.Cobbler.WakeReobserveTest do
  @moduledoc """
  Hermetic DataCase matrix for wake-to-reobserve (§P4) under `ManualClock`:

  - fresh snapshot → admit → renew + resume (lease `renewal_due → renewed`
    chained to the fresh snapshot, run `suspended → starting`, goal
    `sleeping → evaluating → queued`, dispatch still gated);
  - refused snapshot → defer → expire + checkpoint + resleep with a new
    `wake_at` (run stays suspended, checkpoint contents carry the
    no-model-fallback provenance);
  - stale snapshot → require_confirmation → stay asleep (no resume, no
    lease change, operator surface returned);
  - probe failure → the intent stays due and nothing is appended.

  Locking note (standing contract): the wake path is new surface in this
  slice, so on the pre-fix commit these tests error on the missing modules
  (documentation, not behavior-change locks). The P5 `GoalLifecycle`
  clauses exercised here carry their own true locks in
  `GoalLifecycleSleepingTest`. Stated honestly here rather than claimed as
  coverage.
  """
  use Shoestring.DataCase, async: false

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers

  alias Oban.Job
  alias Shoestring.Cobbler.{Dispatcher, Wakeups, WakeupRecord}

  alias Shoestring.Harness.{
    CapacitySnapshot,
    CheckpointRecord,
    ExecutionLeaseRecord,
    Projector,
    RunRecord
  }

  alias Shoestring.Test.ManualClock
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.TrajectoryEvent

  @t0 ~U[2026-09-07 12:00:00.000000Z]

  setup do
    ManualClock.set(@t0)
    goal = create_goal!()
    task = insert_task!(goal)
    snapshot_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, snapshot_id)

    admission =
      append_admission_event!(
        goal.id,
        grant_payload(snapshot_id, "admit", "automatic_admission_eligible")
      )

    command = claim_command(admission, command_id: "cmd-wake-matrix-grant")

    assert {:ok, leased} =
             Dispatcher.claim_and_gate(goal.id, command,
               now: @t0,
               grant_lease: [task_id: task.id, clock: ManualClock, now: @t0]
             )

    run = leased.run
    grant_id = leased.grant_id

    assert {:ok, _} = Projector.project(goal.id, clock: ManualClock)
    suspend_run!(goal, run)
    assert {:ok, _} = Projector.project(goal.id, clock: ManualClock)
    assert Repo.get!(RunRecord, run.id).status == "suspended"
    assert Repo.get!(ExecutionLeaseRecord, grant_id).status == "active"

    {:ok, goal: goal, task: task, run: run, grant_id: grant_id}
  end

  test "fresh snapshot renews the lease and resumes the run", %{
    goal: goal,
    run: run,
    grant_id: grant_id
  } do
    snapshot = eligible_snapshot!()
    wakeup = schedule_wake!(goal, run, "cmd-wake-fresh")
    # P1 durable delivery: the setup grant enqueued exactly one dispatch job.
    # The wake path itself must add none.
    dispatch_jobs_before = dispatch_job_count()

    assert {:ok, summary} =
             Wakeups.perform_wakeup(wakeup.id,
               now: ManualClock.now(),
               clock: ManualClock,
               observe: fn -> {:ok, snapshot} end
             )

    assert summary.branch == :admitted
    assert summary.lifecycle == :queued
    assert summary.lease == :renewed
    assert summary.run == :starting
    assert summary.dispatch == :gated

    lease = Repo.get!(ExecutionLeaseRecord, grant_id)
    assert lease.status == "renewed"
    assert lease.admitted_snapshot_id == snapshot.snapshot_id
    assert Repo.get!(RunRecord, run.id).status == "starting"
    assert Repo.get!(WakeupRecord, wakeup.id).status == "woken"

    # No checkpoint is written on the admit path ...
    assert Repo.aggregate(CheckpointRecord, :count, :id) == 0
    # ... and the wake dispatch stays behind the gate: the wakeup enqueues no
    # new effect jobs beyond the setup grant's durable delivery.
    assert dispatch_job_count() == dispatch_jobs_before
  end

  test "refused snapshot expires the lease, checkpoints, and resleeps", %{
    goal: goal,
    run: run,
    grant_id: grant_id
  } do
    snapshot = refused_snapshot!()
    wakeup = schedule_wake!(goal, run, "cmd-wake-refused")

    assert {:ok, summary} =
             Wakeups.perform_wakeup(wakeup.id,
               now: ManualClock.now(),
               clock: ManualClock,
               observe: fn -> {:ok, snapshot} end
             )

    assert summary.branch == :deferred
    assert summary.lifecycle == :sleeping
    assert summary.lease == :checkpoint_required

    # The run stays suspended.
    assert Repo.get!(RunRecord, run.id).status == "suspended"
    assert Repo.get!(ExecutionLeaseRecord, grant_id).status == "checkpoint_required"

    # Checkpoint contents exist under the deterministic wakeup id with the
    # no-model-fallback provenance ...
    checkpoint = Repo.get!(CheckpointRecord, wakeup.id)
    assert checkpoint.goal_id == goal.id
    assert checkpoint.run_id == run.id

    assert checkpoint.extensions["shoestring:synthesized_without_model"] ==
             "checkpoint-fallback-v1"

    assert String.length(checkpoint.next_action) > 0
    assert summary.checkpoint.checkpoint_id == wakeup.id

    # ... and a NEW wake intent carries the evaluation's defer_until.
    assert Repo.get!(WakeupRecord, wakeup.id).status == "woken"

    [resleep] =
      Repo.all(from w in WakeupRecord, where: w.goal_id == ^goal.id and w.id != ^wakeup.id)

    assert DateTime.compare(resleep.wake_at, ManualClock.now()) == :gt
    assert resleep.wake_at == summary.resleep_wake_at
    assert resleep.status == "scheduled"
    assert resleep.idempotency_key =~ "wakeup:#{goal.id}:"
  end

  test "stale snapshot stays asleep with no resume and no lease change", %{
    goal: goal,
    run: run,
    grant_id: grant_id
  } do
    snapshot = fresh_then_stale_snapshot!()
    wakeup = schedule_wake!(goal, run, "cmd-wake-stale")

    assert {:ok, summary} =
             Wakeups.perform_wakeup(wakeup.id,
               now: ManualClock.now(),
               clock: ManualClock,
               observe: fn -> {:ok, snapshot} end
             )

    assert summary.branch == :require_confirmation
    assert summary.lifecycle == :sleeping
    assert summary.operator_action == :confirmation_required

    # No resume ...
    assert Repo.get!(RunRecord, run.id).status == "suspended"
    # ... no lease change ...
    assert Repo.get!(ExecutionLeaseRecord, grant_id).status == "active"
    # ... no checkpoint, no resleep.
    assert Repo.aggregate(CheckpointRecord, :count, :id) == 0
    assert Repo.aggregate(from(w in WakeupRecord, where: w.goal_id == ^goal.id), :count, :id) == 1
    assert Repo.get!(WakeupRecord, wakeup.id).status == "woken"
  end

  test "probe failure leaves the intent due and appends nothing", %{
    goal: goal,
    run: run,
    grant_id: grant_id
  } do
    wakeup = schedule_wake!(goal, run, "cmd-wake-probe-fail")
    events_before = Repo.aggregate(TrajectoryEvent, :count, :id)

    assert {:error, {:observation_failed, :probe_boom}} =
             Wakeups.perform_wakeup(wakeup.id,
               now: ManualClock.now(),
               clock: ManualClock,
               observe: fn -> {:error, :probe_boom} end
             )

    assert Repo.get!(WakeupRecord, wakeup.id).status == "due"
    assert Repo.aggregate(TrajectoryEvent, :count, :id) == events_before
    assert Repo.get!(RunRecord, run.id).status == "suspended"
    assert Repo.get!(ExecutionLeaseRecord, grant_id).status == "active"
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  defp insert_task!(goal) do
    %Shoestring.Trajectory.Task{}
    |> Shoestring.Trajectory.Task.changeset(%{"title" => "Wake task"})
    |> Ecto.Changeset.put_change(:goal_id, goal.id)
    |> Repo.insert!()
  end

  defp dispatch_job_count do
    Repo.aggregate(from(job in Job, where: job.queue == "dispatch"), :count, :id)
  end

  defp grant_payload(snapshot_id, result, reason_code, opts \\ []) do
    admission_payload()
    |> Map.merge(%{
      "decision_id" => Keyword.get(opts, :decision_id, Ecto.UUID.generate()),
      "result" => result,
      "reason_code" => reason_code,
      "explanation" => "Wake matrix decision: #{reason_code}",
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

  defp snapshot_source do
    %{
      adapter_id: "shoestring.harness.fake",
      provider_id: "codex",
      invocation_mode: "headless",
      event: :explicit_read
    }
  end

  defp observed_windows(reset_at) do
    [
      %{kind: "five_hour", state: :observed, used_percent: 10.0, reset_at: reset_at},
      %{kind: "weekly", state: :observed, used_percent: 12.0, reset_at: reset_at}
    ]
  end

  defp eligible_snapshot! do
    now = ManualClock.now()

    attrs = %{
      version: 2,
      snapshot_id: Ecto.UUID.generate(),
      capacity_state: :observed,
      windows: observed_windows(DateTime.add(now, 7_200, :second)),
      observed_at: now,
      freshness: %{max_age_seconds: 300},
      source: snapshot_source(),
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

  defp refused_snapshot! do
    now = ManualClock.now()

    attrs = %{
      version: 2,
      snapshot_id: Ecto.UUID.generate(),
      capacity_state: :refused,
      windows: [
        %{kind: "five_hour", state: :unknown, reason: "quota refused by provider"},
        %{kind: "weekly", state: :unknown, reason: "quota refused by provider"}
      ],
      observed_at: now,
      freshness: %{max_age_seconds: 300},
      source: snapshot_source(),
      scope: "account:codex",
      confidence: :medium,
      support_tier: :proactive,
      compatibility_state: :compatible,
      reason: "provider reported quota refusal",
      extensions: %{}
    }

    {:ok, snapshot} = CapacitySnapshot.new(attrs, now: now)
    snapshot
  end

  # Built fresh at T0, evaluated after the freshness window lapses: the
  # bypassable stale path (`require_confirmation`).
  defp fresh_then_stale_snapshot! do
    snapshot = eligible_snapshot!()
    ManualClock.advance(3_600, :second)
    snapshot
  end
end
