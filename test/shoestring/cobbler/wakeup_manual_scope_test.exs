defmodule Shoestring.Cobbler.WakeupManualScopeTest do
  @moduledoc """
  A lease-decline recheck for an operator-confirmed MANUAL run.

  Live (final-acceptance.md §5.2), every `lease_decline_recheck` wake of a
  manual run failed `{:observation_failed, :no_observation_for_provider}`:
  a manual run is scoped `account:manual`, which no provider reading ever
  carries, so the Observatory could never match it. The wake stayed `due`,
  its job retried to discard, and every boot's reconcile re-enqueued it.

  Hermetic: DataCase, Oban `testing: :manual`, `ManualClock`, an observe spy
  or the production `WakeupObserve` against an empty test ledger. Never a
  provider CLI, never the network.

  Lock ledger (pre-fix `4d5975e`, the commit before the wake
  change): the two manual-scope tests FAIL there for the behavioural reason —
  the wake observes and returns `{:error, {:observation_failed, _}}` instead
  of recording a refusal. The provider-scope twin passes there: it is
  documentation that real provider recovery is unchanged.
  """
  use Shoestring.DataCase, async: false

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers

  alias Oban.Job
  alias Shoestring.Cobbler.{Dispatcher, WakeupObserve, WakeupRecord, Wakeups, WakeupWorker}
  alias Shoestring.Harness.{Projector, RunRecord}
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Test.ManualClock
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

  # LOCK
  test "a manual-scope decline recheck refuses durably without observing, once" do
    %{goal: goal, run: run} = suspended_fixture(:manual)
    wakeup = schedule_decline_wake!(goal, run)
    test_pid = self()
    effects = ["run.cancelled", "run.cancelling", "run.resuming", "dispatch.requested"]
    effects_before = event_count(goal.id, effects)

    observe = fn scoping ->
      send(test_pid, {:observed, scoping})
      {:error, :no_observation_for_provider}
    end

    assert {:ok, summary} =
             Wakeups.perform_wakeup(wakeup.id, observe: observe, clock: ManualClock)

    assert summary.branch == :require_confirmation
    assert summary.reason_code == "manual_scope_not_resumable"
    assert summary.operator_action == :confirmation_required
    refute_received {:observed, _}

    # Settled: the row is terminal, so neither a retry nor a boot reconcile
    # can bring the wake back.
    assert Repo.get!(WakeupRecord, wakeup.id).status == "woken"

    assert [decision] = manual_refusals(goal.id)
    assert decision.run_id == run.id
    assert decision.payload["result"] == "require_confirmation"
    assert decision.payload["scope"] == "account:manual"
    assert decision.payload["candidate"]["support_tier"] == "manual"
    assert decision.payload["explanation"] =~ "cannot resume automatically"

    # The run is left exactly where the decline put it: suspended at its
    # checkpoint, not cancelled, not resumed.
    assert {:ok, _} = Projector.project(goal.id, clock: ManualClock)
    assert Repo.get!(RunRecord, run.id).status == "suspended"
    assert event_count(goal.id, effects) == effects_before

    assert {:ok, %{branch: :already_woken}} =
             Wakeups.perform_wakeup(wakeup.id, observe: observe, clock: ManualClock)

    jobs_before = wakeup_job_count()
    assert {:ok, %{requeued: 0}} = reconcile_summary()
    assert wakeup_job_count() == jobs_before
    assert length(manual_refusals(goal.id)) == 1
    refute_received {:observed, _}
  end

  # LOCK: the production wiring (MFA observe against the Observatory
  # ledger), through the worker exactly as the live node ran it.
  test "the worker settles a manual-scope wake instead of failing it" do
    Application.put_env(:shoestring, :wakeup_observe, {WakeupObserve, :observe, []})
    %{goal: goal, run: run} = suspended_fixture(:manual)
    wakeup = schedule_decline_wake!(goal, run)

    assert :ok = WakeupWorker.perform(worker_job(wakeup))
    assert Repo.get!(WakeupRecord, wakeup.id).status == "woken"
    assert [_decision] = manual_refusals(goal.id)
  end

  # DOCUMENTATION: a provider-scoped wake still re-observes, and a failed
  # observation still leaves the intent due for a later retry.
  test "a provider-scope wake still observes and stays due when observation fails" do
    %{goal: goal, run: run} = suspended_fixture(:provider)
    wakeup = schedule_decline_wake!(goal, run)
    test_pid = self()

    observe = fn scoping ->
      send(test_pid, {:observed, scoping})
      {:error, :no_observation_for_provider}
    end

    assert {:error, {:observation_failed, :no_observation_for_provider}} =
             Wakeups.perform_wakeup(wakeup.id, observe: observe, clock: ManualClock)

    assert_received {:observed, %{provider_id: "codex"}}
    assert Repo.get!(WakeupRecord, wakeup.id).status == "due"
    assert manual_refusals(goal.id) == []
  end

  # ----------------------------------------------------------------------------
  # Fixture
  # ----------------------------------------------------------------------------

  defp suspended_fixture(kind) do
    goal = create_goal!()

    task =
      %Shoestring.Trajectory.Task{}
      |> Shoestring.Trajectory.Task.changeset(%{"title" => "Manual wake task"})
      |> Ecto.Changeset.put_change(:goal_id, goal.id)
      |> Repo.insert!()

    snapshot_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, snapshot_id)
    admission = append_admission_event!(goal.id, admission(kind, snapshot_id))

    assert {:ok, leased} =
             Dispatcher.claim_and_gate(goal.id, claim_command(admission),
               now: @t0,
               grant_lease: [task_id: task.id, clock: ManualClock, now: @t0]
             )

    run = leased.run

    for type <- ["run.starting", "run.running", "run.pausing", "run.suspended"] do
      {:ok, _} =
        Trajectory.append(
          goal.id,
          %{
            "type" => type,
            "schema_version" => 1,
            "actor" => "elf",
            "occurred_at" => ManualClock.now(),
            "payload" => %{"run_id" => run.id}
          },
          trusted: [run_id: run.id]
        )
    end

    assert {:ok, _} = Projector.project(goal.id, clock: ManualClock)
    assert Repo.get!(RunRecord, run.id).status == "suspended"
    %{goal: goal, run: run}
  end

  defp admission(:manual, snapshot_id) do
    admission_payload(scope: "account:manual", adapter_id: "codex_app_server_stdio")
    |> Map.merge(%{
      "reason_code" => "manual_operator_confirmed",
      "explanation" => "Operator-confirmed manual bounded run",
      "observation" => %{
        "snapshot_id" => snapshot_id,
        "confidence" => "none",
        "freshness" => "fresh"
      },
      "proposed_bounds" => bounds()
    })
    |> put_in(["candidate", "support_tier"], "manual")
  end

  defp admission(:provider, snapshot_id) do
    admission_payload()
    |> Map.merge(%{
      "observation" => %{
        "snapshot_id" => snapshot_id,
        "confidence" => "high",
        "freshness" => "fresh"
      },
      "proposed_bounds" => bounds()
    })
  end

  defp bounds do
    %{
      "response_budget" => 10,
      "tool_budget" => 25,
      "deadline" => DateTime.to_iso8601(DateTime.add(@t0, 60, :second)),
      "checkpoint_cadence" => 10,
      "reserves" => %{"response" => 0, "tool" => 0}
    }
  end

  # The shape the Elf schedules after a decline (`Shoestring.Elves.Elf`):
  # command id `elf-lease-decline:<dispatch_id>`, reason
  # `lease_decline_recheck`, bound to the run.
  defp schedule_decline_wake!(goal, run) do
    assert {:ok, %{wakeup: wakeup}} =
             Wakeups.schedule(goal.id,
               command_id: "elf-lease-decline:#{run.dispatch_id || run.id}",
               reason: "lease_decline_recheck",
               run_id: run.id,
               wake_at: @t0,
               now: @t0,
               clock: ManualClock
             )

    wakeup
  end

  defp manual_refusals(goal_id) do
    Repo.all(
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^goal_id and event.type == "admission.decided" and
            fragment("(? ->> ?) = ?", event.payload, "reason_code", "manual_scope_not_resumable"),
        order_by: [asc: event.sequence]
    )
  end

  defp reconcile_summary do
    {:ok, summary} = Wakeups.reconcile(clock: ManualClock)
    {:ok, %{requeued: Map.get(summary, :repaired_count, 0)}}
  end

  defp wakeup_job_count do
    Repo.aggregate(from(job in Job, where: job.queue == "wakeup"), :count, :id)
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

  defp restore_env(key, nil), do: Application.delete_env(:shoestring, key)
  defp restore_env(key, value), do: Application.put_env(:shoestring, key, value)
end
