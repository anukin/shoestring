defmodule Shoestring.Cobbler.WakeupProductionTest do
  @moduledoc """
  Hermetic DataCase tests for production wakeups (loop-closure I4):

  - P1: `WakeupObserve.observe/0` re-probes the real Observatory ledger
    (fail-closed on an empty/unreadable ledger); the worker without a
    configured `:wakeup_observe` fails closed (`missing_observe_fun`) and
    leaves the intent due; production config wires the MFA tuple (asserted
    at the `Application.get_env/2` contract level, not by booting prod).
  - P2: an admitted wake dispatches exactly one continuation through the
    durable `Dispatches.enqueue/3` pipeline (new run of the same goal+task,
    wakeup-derived dispatch id, one dispatch-queue job); a double perform
    is one effect; an admit with no run leaves dispatch `:gated`.

  Locking notes (standing contract), verified against `85437ed`:

  - the admitted-dispatch assertions FAIL on base for the right behavioural
    reason (base enqueues nothing: zero `harness_dispatches` rows and zero
    `dispatch`-queue jobs where one of each is asserted) — true locks;
  - the no-run admit twin, the worker fail-closed case, the refused-via-worker
    case, and the `WakeupObserve` ledger cases PASS-or-ERROR on base without
    a behaviour change (fail-closed default and defer path predate this
    slice; `WakeupObserve` is new surface) — documentation, stated honestly.
  """
  use Shoestring.DataCase, async: false

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers

  alias Oban.Job
  alias Shoestring.Cobbler.{Dispatcher, WakeupObserve, Wakeups, WakeupRecord, WakeupWorker}

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

  setup do
    ManualClock.set(@t0)

    previous_clock = Application.get_env(:shoestring, :dispatch_clock)
    previous_observe = Application.get_env(:shoestring, :wakeup_observe)

    Application.put_env(:shoestring, :dispatch_clock, ManualClock)

    on_exit(fn ->
      restore_env(:dispatch_clock, previous_clock)
      restore_env(:wakeup_observe, previous_observe)
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:shoestring, key)
  defp restore_env(key, value), do: Application.put_env(:shoestring, key, value)

  # ----------------------------------------------------------------------------
  # P2: admitted dispatches exactly one continuation (locks)
  # ----------------------------------------------------------------------------

  test "admitted wake dispatches one continuation through the durable pipeline" do
    %{goal: goal, run: run, grant_id: grant_id} = sleeping_fixture("cmd-wake-prod-dispatch")
    snapshot = eligible_snapshot!()
    wakeup = schedule_wake!(goal, run, "cmd-wake-prod-dispatch")

    assert {:ok, summary} =
             Wakeups.perform_wakeup(wakeup.id,
               now: ManualClock.now(),
               clock: ManualClock,
               observe: fn -> {:ok, snapshot} end
             )

    assert summary.branch == :admitted
    assert summary.lifecycle == :queued

    # Exactly one continuation dispatch record keyed by the wakeup-derived
    # dispatch id (asserted before touching the summary shape so a missing
    # dispatch fails here for the behavioural reason, not on map access).
    # Total records are 2: the fixture's setup durable delivery (I1 entry
    # path) plus this wake continuation.
    assert Repo.aggregate(DispatchRecord, :count, :dispatch_id) == 2

    assert summary.dispatch.outcome == :dispatched
    assert summary.dispatch.dispatch_id == wakeup.id

    assert %{goal_id: goal_id, run_id: cont_run_id, status: "requested"} =
             Repo.get!(DispatchRecord, wakeup.id)

    assert goal_id == goal.id
    assert cont_run_id != run.id

    continuation = Repo.get!(RunRecord, cont_run_id)
    assert continuation.goal_id == goal.id
    assert continuation.task_id == run.task_id
    assert continuation.dispatch_id == wakeup.id

    # ... and exactly one dispatch-queue delivery attempt for the wake
    # continuation (plus the fixture setup delivery).
    assert dispatch_job_count() == 2

    # The wake's own effects still hold: lease renewed, run resumed, row woken.
    assert Repo.get!(ExecutionLeaseRecord, grant_id).status == "renewed"
    assert Repo.get!(RunRecord, run.id).status == "starting"
    assert Repo.get!(WakeupRecord, wakeup.id).status == "woken"
  end

  test "double perform dispatches once" do
    %{goal: goal, run: run} = sleeping_fixture("cmd-wake-prod-double")
    snapshot = eligible_snapshot!()
    wakeup = schedule_wake!(goal, run, "cmd-wake-prod-double")
    opts = [now: ManualClock.now(), clock: ManualClock, observe: fn -> {:ok, snapshot} end]

    assert {:ok, %{branch: :admitted}} = Wakeups.perform_wakeup(wakeup.id, opts)

    assert {:ok, %{outcome: :already_woken, branch: :already_woken}} =
             Wakeups.perform_wakeup(wakeup.id, opts)

    # Double perform adds nothing: still exactly the fixture setup delivery
    # plus the single wake continuation (2 records, 2 jobs).
    assert Repo.aggregate(DispatchRecord, :count, :dispatch_id) == 2
    assert dispatch_job_count() == 2
    assert Repo.get!(WakeupRecord, wakeup.id).status == "woken"
  end

  test "admitted wake through the worker dispatches when observe is configured" do
    %{goal: goal, run: run} = sleeping_fixture("cmd-wake-prod-worker")
    snapshot = eligible_snapshot!()
    wakeup = schedule_wake!(goal, run, "cmd-wake-prod-worker")

    Application.put_env(:shoestring, :wakeup_observe, fn -> {:ok, snapshot} end)

    assert :ok = WakeupWorker.perform(worker_job(wakeup))

    assert Repo.get!(WakeupRecord, wakeup.id).status == "woken"
    # Fixture setup delivery plus the worker-driven continuation.
    assert Repo.aggregate(DispatchRecord, :count, :dispatch_id) == 2
    assert %DispatchRecord{goal_id: goal_id} = Repo.get!(DispatchRecord, wakeup.id)
    assert goal_id == goal.id
    # Setup delivery job plus the worker-driven continuation job.
    assert dispatch_job_count() == 2
  end

  test "admit with no run leaves dispatch gated" do
    goal = create_goal!()
    _admission = append_admission_event!(goal.id)
    snapshot = eligible_snapshot!()

    assert {:ok, %{wakeup: wakeup}} =
             Wakeups.schedule(goal.id,
               command_id: "cmd-wake-prod-norun",
               wake_at: @t0,
               now: @t0,
               clock: ManualClock
             )

    assert {:ok, summary} =
             Wakeups.perform_wakeup(wakeup.id,
               now: ManualClock.now(),
               clock: ManualClock,
               observe: fn -> {:ok, snapshot} end
             )

    assert summary.branch == :admitted
    assert summary.lifecycle == :queued
    assert summary.dispatch == :gated
    assert Repo.get!(WakeupRecord, wakeup.id).status == "woken"
    assert Repo.aggregate(DispatchRecord, :count, :dispatch_id) == 0
    assert dispatch_job_count() == 0
  end

  # ----------------------------------------------------------------------------
  # P1: production observe wiring
  # ----------------------------------------------------------------------------

  test "worker without configured observe fails closed and leaves the intent due" do
    Application.delete_env(:shoestring, :wakeup_observe)

    goal = create_goal!()
    admission = append_admission_event!(goal.id)
    events_before = Repo.aggregate(TrajectoryEvent, :count, :id)

    assert {:ok, %{wakeup: wakeup}} =
             Wakeups.schedule(goal.id,
               command_id: "cmd-wake-prod-failclosed",
               wake_at: @t0,
               now: @t0,
               clock: ManualClock,
               decision_event_id: admission.id
             )

    assert {:error, {:observation_failed, :missing_observe_fun}} =
             WakeupWorker.perform(worker_job(wakeup))

    assert Repo.get!(WakeupRecord, wakeup.id).status == "due"
    assert Repo.aggregate(TrajectoryEvent, :count, :id) == events_before
    assert Repo.aggregate(DispatchRecord, :count, :dispatch_id) == 0
  end

  test "worker with configured observe reaches the deferred branch" do
    %{goal: goal, run: run, grant_id: grant_id} = sleeping_fixture("cmd-wake-prod-refused")
    snapshot = refused_snapshot!()
    wakeup = schedule_wake!(goal, run, "cmd-wake-prod-refused")

    Application.put_env(:shoestring, :wakeup_observe, fn -> {:ok, snapshot} end)

    assert :ok = WakeupWorker.perform(worker_job(wakeup))

    assert Repo.get!(WakeupRecord, wakeup.id).status == "woken"
    assert Repo.get!(RunRecord, run.id).status == "suspended"
    assert Repo.get!(ExecutionLeaseRecord, grant_id).status == "checkpoint_required"
    # Deferred path adds no dispatch: only the fixture setup delivery remains.
    assert Repo.aggregate(DispatchRecord, :count, :dispatch_id) == 1
  end

  test "production observe returns the newest ledger observation for the run provider/scope" do
    scoping = %{provider_id: "codex", scope: "account:codex"}
    assert {:error, :no_observation} = WakeupObserve.observe(scoping)

    now = ManualClock.now()
    earlier = DateTime.add(now, -600, :second)
    recent = DateTime.add(now, -60, :second)

    {:ok, older} =
      CapacitySnapshot.new(snapshot_attrs(Ecto.UUID.generate(), earlier), now: earlier)

    {:ok, fresh} = CapacitySnapshot.new(snapshot_attrs(Ecto.UUID.generate(), recent), now: recent)

    # A foreign provider's snapshot is globally newest, but must never leak
    # into this provider's wake decision.
    {:ok, foreign} =
      CapacitySnapshot.new(foreign_snapshot_attrs(Ecto.UUID.generate(), now), now: now)

    for snapshot <- [older, fresh, foreign] do
      {:ok, :persisted, _} = Shoestring.Harness.Observatory.ingest(snapshot)
    end

    assert {:ok, %CapacitySnapshot{snapshot_id: snapshot_id}} = WakeupObserve.observe(scoping)
    assert snapshot_id == fresh.snapshot_id

    assert {:ok, %CapacitySnapshot{snapshot_id: foreign_id}} =
             WakeupObserve.observe(%{provider_id: "other", scope: "account:other"})

    assert foreign_id == foreign.snapshot_id

    assert {:error, :no_observation_for_provider} =
             WakeupObserve.observe(%{provider_id: "missing", scope: "account:missing"})
  end

  test "production config wires the MFA observe tuple" do
    # The runtime config file (prod section) must point `:wakeup_observe` at
    # the Observatory-backed probe. Asserted here as a file contract so the
    # wiring cannot silently drift back to "unconfigured in production".
    runtime = File.read!(Path.join([File.cwd!(), "config", "runtime.exs"]))

    assert runtime =~ ":wakeup_observe"
    assert runtime =~ "WakeupObserve"
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  defp sleeping_fixture(command_id) do
    goal = create_goal!()
    task = insert_task!(goal)
    snapshot_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, snapshot_id)

    admission =
      append_admission_event!(
        goal.id,
        grant_payload(snapshot_id, "admit", "automatic_admission_eligible")
      )

    command = claim_command(admission, command_id: command_id)

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

    %{goal: goal, task: task, run: run, grant_id: grant_id}
  end

  defp insert_task!(goal) do
    %Shoestring.Trajectory.Task{}
    |> Shoestring.Trajectory.Task.changeset(%{"title" => "Wake task"})
    |> Ecto.Changeset.put_change(:goal_id, goal.id)
    |> Repo.insert!()
  end

  defp grant_payload(snapshot_id, result, reason_code, opts \\ []) do
    admission_payload()
    |> Map.merge(%{
      "decision_id" => Keyword.get(opts, :decision_id, Ecto.UUID.generate()),
      "result" => result,
      "reason_code" => reason_code,
      "explanation" => "Wake production decision: #{reason_code}",
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

    run_opts = if run, do: [run_id: run.id], else: []

    assert {:ok, %{wakeup: wakeup, outcome: :recorded}} =
             Wakeups.schedule(
               goal.id,
               [command_id: command_id, wake_at: now, now: now, clock: ManualClock] ++ run_opts
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

  defp dispatch_job_count do
    Repo.aggregate(from(job in Job, where: job.queue == "dispatch"), :count, :id)
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

    {:ok, snapshot} =
      CapacitySnapshot.new(snapshot_attrs(Ecto.UUID.generate(), now), now: now)

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

  defp foreign_snapshot_attrs(snapshot_id, observed_at) do
    %{
      version: 2,
      snapshot_id: snapshot_id,
      capacity_state: :observed,
      windows: observed_windows(DateTime.add(observed_at, 7_200, :second)),
      observed_at: observed_at,
      freshness: %{max_age_seconds: 300},
      source: %{
        adapter_id: "shoestring.harness.fake",
        provider_id: "other",
        invocation_mode: "headless",
        event: :explicit_read
      },
      scope: "account:other",
      confidence: :high,
      support_tier: :proactive,
      compatibility_state: :compatible,
      reason: nil,
      extensions: %{}
    }
  end

  defp snapshot_attrs(snapshot_id, observed_at) do
    %{
      version: 2,
      snapshot_id: snapshot_id,
      capacity_state: :observed,
      windows: observed_windows(DateTime.add(observed_at, 7_200, :second)),
      observed_at: observed_at,
      freshness: %{max_age_seconds: 300},
      source: snapshot_source(),
      scope: "account:codex",
      confidence: :high,
      support_tier: :proactive,
      compatibility_state: :compatible,
      reason: nil,
      extensions: %{}
    }
  end
end
