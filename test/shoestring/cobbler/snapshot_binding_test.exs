defmodule Shoestring.Cobbler.SnapshotBindingTest do
  @moduledoc """
  Hermetic DataCase tests for capacity-snapshot → candidate binding (W1):

  - P2 locks: a handed snapshot whose recorded provider/scope disagrees with
    the candidate hard-stops with `snapshot_provider_mismatch`
    (unbypassable, mirroring the `scope_mismatch` pattern), in both
    directions plus scope-only mismatch, through `AdmissionEvaluation` and
    end-to-end through `Wakeups.perform_wakeup/2`.
  - P1 documentation (new `WakeupObserve.observe/1` surface): scoped newest
    wins, foreign snapshots never leak across providers, and
    `:no_observation_for_provider` fails closed with the intent left due.
  - P3 controls: nil/unknown snapshots still require confirmation.

  Lock-vs-documentation ledger (standing contract): the P2 tests call only
  APIs that exist on the pre-fix commit (`evaluate/5`, `perform_wakeup/2`
  with a zero-arity `:observe`) and FAIL there for the right behavioural
  reason (wrong-provider admit where refusal is asserted). The P1 tests
  exercise the new `observe/1` entry point, which does not exist pre-fix,
  and are documentation for the new surface.
  """
  use Shoestring.DataCase, async: false

  import Shoestring.Test.CobblerHelpers

  alias Shoestring.Cobbler.{Dispatcher, WakeupObserve, Wakeups, WakeupRecord}

  alias Shoestring.Harness.{
    CapacitySnapshot,
    DispatchRecord,
    ExecutionLeaseRecord,
    Projector,
    RunRecord
  }

  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Test.ManualClock
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.TrajectoryEvent

  @t0 ~U[2026-09-07 12:00:00.000000Z]

  @candidate %{
    provider_id: "codex",
    adapter_id: "codex_app_server",
    support_tier: :proactive,
    compatibility_state: :compatible,
    scope: "account:codex",
    capabilities: ["supervised_execution"]
  }

  @valid_override %{
    confirmed_by: "operator:alice",
    confirmed_at: "2026-09-07T12:00:00Z",
    intent: "manual_override",
    target_provider_id: "codex",
    target_scope: "account:codex"
  }

  setup do
    ManualClock.set(@t0)

    previous_clock = Application.get_env(:shoestring, :dispatch_clock)

    Application.put_env(:shoestring, :dispatch_clock, ManualClock)

    on_exit(fn -> restore_env(:dispatch_clock, previous_clock) end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:shoestring, key)
  defp restore_env(key, value), do: Application.put_env(:shoestring, key, value)

  # ----------------------------------------------------------------------------
  # P2 locks: snapshot provider/scope binding hard-stop
  # ----------------------------------------------------------------------------

  test "foreign-provider snapshot hard-stops a codex candidate" do
    snapshot = healthy_snapshot!(provider_id: "other", scope: "account:other")

    assert {:ok, decision} =
             Shoestring.Cobbler.AdmissionEvaluation.evaluate(%{}, @candidate, snapshot, nil,
               now: @t0
             )

    assert decision.result == :reject
    assert decision.reason_code == "snapshot_provider_mismatch"
  end

  test "codex snapshot hard-stops a foreign candidate (reverse direction)" do
    candidate = %{@candidate | provider_id: "other", scope: "account:other"}
    snapshot = healthy_snapshot!(provider_id: "codex", scope: "account:codex")

    assert {:ok, decision} =
             Shoestring.Cobbler.AdmissionEvaluation.evaluate(%{}, candidate, snapshot, nil,
               now: @t0
             )

    assert decision.result == :reject
    assert decision.reason_code == "snapshot_provider_mismatch"
  end

  test "same provider with a different scope hard-stops" do
    snapshot = healthy_snapshot!(provider_id: "codex", scope: "account:other")

    assert {:ok, decision} =
             Shoestring.Cobbler.AdmissionEvaluation.evaluate(%{}, @candidate, snapshot, nil,
               now: @t0
             )

    assert decision.result == :reject
    assert decision.reason_code == "snapshot_provider_mismatch"
  end

  test "snapshot binding cannot be bypassed by manual confirmation" do
    snapshot = healthy_snapshot!(provider_id: "other", scope: "account:other")
    req = %{override: @valid_override}

    assert {:ok, decision} =
             Shoestring.Cobbler.AdmissionEvaluation.evaluate(req, @candidate, snapshot, nil,
               now: @t0
             )

    assert decision.result == :reject
    assert decision.reason_code == "snapshot_provider_mismatch"
  end

  test "map-form snapshot with a foreign identity hard-stops, even when confirmed" do
    snapshot = %{
      "source" => %{"provider_id" => "other"},
      "scope" => "account:other",
      "snapshot_id" => Ecto.UUID.generate()
    }

    assert {:ok, decision} =
             Shoestring.Cobbler.AdmissionEvaluation.evaluate(
               %{override: @valid_override},
               @candidate,
               snapshot,
               nil,
               now: @t0
             )

    assert decision.result == :reject
    assert decision.reason_code == "snapshot_provider_mismatch"
  end

  test "wake admission on a foreign snapshot rejects instead of admitting" do
    %{goal: goal, run: run} = sleeping_fixture("cmd-bind-foreign")
    snapshot = healthy_snapshot!(provider_id: "other", scope: "account:other")
    wakeup = schedule_wake!(goal, run, "cmd-bind-foreign")

    assert {:ok, summary} =
             Wakeups.perform_wakeup(wakeup.id,
               now: ManualClock.now(),
               clock: ManualClock,
               observe: fn -> {:ok, snapshot} end
             )

    assert summary.branch == :rejected
    assert summary.reason_code == "snapshot_provider_mismatch"
    assert Repo.get!(WakeupRecord, wakeup.id).status == "woken"
    assert Repo.aggregate(DispatchRecord, :count, :dispatch_id) == 1
  end

  # ----------------------------------------------------------------------------
  # P3 controls (pass pre-fix too — documentation of preserved behaviour)
  # ----------------------------------------------------------------------------

  test "bound snapshot still admits" do
    snapshot = healthy_snapshot!(provider_id: "codex", scope: "account:codex")

    assert {:ok, decision} =
             Shoestring.Cobbler.AdmissionEvaluation.evaluate(%{}, @candidate, snapshot, nil,
               now: @t0
             )

    assert decision.result == :admit
    assert decision.reason_code == "automatic_admission_eligible"
  end

  test "nil snapshot still requires confirmation" do
    assert {:ok, decision} =
             Shoestring.Cobbler.AdmissionEvaluation.evaluate(%{}, @candidate, nil, nil, now: @t0)

    assert decision.result == :require_confirmation
    assert decision.reason_code == "unknown_capacity"
  end

  test "snapshot without identity fields stays unknown, never a binding reject" do
    snapshot = %{"snapshot_id" => Ecto.UUID.generate()}

    assert {:ok, decision} =
             Shoestring.Cobbler.AdmissionEvaluation.evaluate(%{}, @candidate, snapshot, nil,
               now: @t0
             )

    assert decision.result == :require_confirmation
    refute decision.reason_code == "snapshot_provider_mismatch"
  end

  # ----------------------------------------------------------------------------
  # P1 documentation: scoped observe (new surface, N/A pre-fix)
  # ----------------------------------------------------------------------------

  test "scoped observe returns the newest observation for that provider/scope only" do
    scoping = %{provider_id: "codex", scope: "account:codex"}
    assert {:error, :no_observation} = WakeupObserve.observe(scoping)

    earlier = DateTime.add(@t0, -600, :second)
    recent = DateTime.add(@t0, -60, :second)

    {:ok, older} =
      CapacitySnapshot.new(
        snapshot_attrs(Ecto.UUID.generate(), earlier, "codex", "account:codex"),
        now: earlier
      )

    {:ok, fresh} =
      CapacitySnapshot.new(
        snapshot_attrs(Ecto.UUID.generate(), recent, "codex", "account:codex"),
        now: recent
      )

    {:ok, foreign} =
      CapacitySnapshot.new(
        snapshot_attrs(Ecto.UUID.generate(), @t0, "other", "account:other"),
        now: @t0
      )

    for snapshot <- [older, fresh, foreign] do
      {:ok, :persisted, _} = Shoestring.Harness.Observatory.ingest(snapshot)
    end

    assert {:ok, %CapacitySnapshot{snapshot_id: fresh_id}} = WakeupObserve.observe(scoping)
    assert fresh_id == fresh.snapshot_id

    assert {:error, :no_observation_for_provider} =
             WakeupObserve.observe(%{provider_id: "missing", scope: "account:missing"})
  end

  test "scoped wake with no observation for the provider fails closed, intent due" do
    %{goal: goal, run: run} = sleeping_fixture("cmd-bind-no-observation")
    wakeup = schedule_wake!(goal, run, "cmd-bind-no-observation")

    # The ledger holds only a foreign snapshot: the scoped probe must refuse
    # it instead of handing it to admission.
    {:ok, foreign} =
      CapacitySnapshot.new(
        snapshot_attrs(Ecto.UUID.generate(), @t0, "other", "account:other"),
        now: @t0
      )

    {:ok, :persisted, _} = Shoestring.Harness.Observatory.ingest(foreign)

    # Baseline after the ingest above (the ingest appends under the
    # observatory goal): the failed wake itself must append nothing.
    events_before = Repo.aggregate(TrajectoryEvent, :count, :id)

    assert {:error, {:observation_failed, :no_observation_for_provider}} =
             Wakeups.perform_wakeup(wakeup.id,
               now: ManualClock.now(),
               clock: ManualClock,
               observe: fn scoping -> WakeupObserve.observe(scoping) end
             )

    assert Repo.get!(WakeupRecord, wakeup.id).status == "due"
    assert Repo.get!(RunRecord, run.id).status == "suspended"
    assert Repo.aggregate(TrajectoryEvent, :count, :id) == events_before
    assert Repo.aggregate(DispatchRecord, :count, :dispatch_id) == 1
  end

  # ----------------------------------------------------------------------------
  # Helpers (self-contained; only pre-fix public APIs)
  # ----------------------------------------------------------------------------

  defp healthy_snapshot!(opts) do
    provider_id = Keyword.fetch!(opts, :provider_id)
    scope = Keyword.fetch!(opts, :scope)
    now = ManualClock.now()

    attrs = %{
      version: 2,
      snapshot_id: Ecto.UUID.generate(),
      capacity_state: :observed,
      windows: [
        %{
          kind: "five_hour",
          state: :observed,
          used_percent: 10.0,
          reset_at: DateTime.add(now, 7_200, :second)
        },
        %{
          kind: "weekly",
          state: :observed,
          used_percent: 12.0,
          reset_at: DateTime.add(now, 7_200, :second)
        }
      ],
      observed_at: now,
      freshness: %{max_age_seconds: 300},
      source: %{
        adapter_id: "shoestring.harness.fake",
        provider_id: provider_id,
        invocation_mode: "headless",
        event: :explicit_read
      },
      scope: scope,
      confidence: :high,
      support_tier: :proactive,
      compatibility_state: :compatible,
      reason: nil,
      extensions: %{}
    }

    {:ok, snapshot} = CapacitySnapshot.new(attrs, now: now)
    snapshot
  end

  defp snapshot_attrs(snapshot_id, observed_at, provider_id, scope) do
    %{
      version: 2,
      snapshot_id: snapshot_id,
      capacity_state: :observed,
      windows: [
        %{
          kind: "five_hour",
          state: :observed,
          used_percent: 10.0,
          reset_at: DateTime.add(observed_at, 7_200, :second)
        },
        %{
          kind: "weekly",
          state: :observed,
          used_percent: 12.0,
          reset_at: DateTime.add(observed_at, 7_200, :second)
        }
      ],
      observed_at: observed_at,
      freshness: %{max_age_seconds: 300},
      source: %{
        adapter_id: "shoestring.harness.fake",
        provider_id: provider_id,
        invocation_mode: "headless",
        event: :explicit_read
      },
      scope: scope,
      confidence: :high,
      support_tier: :proactive,
      compatibility_state: :compatible,
      reason: nil,
      extensions: %{}
    }
  end

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

  defp grant_payload(snapshot_id, result, reason_code) do
    admission_payload()
    |> Map.merge(%{
      "decision_id" => Ecto.UUID.generate(),
      "result" => result,
      "reason_code" => reason_code,
      "explanation" => "Wake binding decision: #{reason_code}",
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
             Wakeups.schedule(
               goal.id,
               command_id: command_id,
               wake_at: now,
               now: now,
               clock: ManualClock,
               run_id: run.id
             )

    wakeup
  end
end
