defmodule Shoestring.Cobbler.WakeupContinuationTest do
  @moduledoc """
  Hermetic DataCase tests for leased same-provider wake continuations:
  the admitted wake dispatches a continuation run carrying the projected
  recovery context, the suspended run's provider identity, and its own
  lease grant — never a nil continuation, a default identity, or unleased
  work.

  Locking notes (standing contract), verified against the pre-fix commit:

  - continuation population, provider preservation, codex-provider mapping,
    new-run lease grant, existing-checkpoint projection, and claim-gate
    refusal FAIL on base for the right behavioural reason (nil
    continuation, Fake-default provider, missing lease row, dispatched
    nil) — true locks;
  - the unknown-provider refusal errors on base via a *different* path
    (base dispatches successfully where fixed code refuses) — true lock;
  - replay idempotency counts pass on base (recovery pre-exists) and are
    documentation, stated honestly.
  """
  use Shoestring.DataCase, async: false

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers

  alias Oban.Job
  alias Shoestring.Cobbler.{Dispatcher, Leases, TaskClaimRecord, Wakeups, WakeupRecord}

  alias Shoestring.Harness.{
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
    :ok
  end

  test "admitted wake dispatches a continuation with projected context, provider identity, and lease" do
    %{goal: goal, run: run} = wake_fixture("cmd-wake-cont")
    snapshot = eligible_snapshot!()
    wakeup = schedule_wake!(goal, run, "cmd-wake-cont")

    assert {:ok, summary} =
             Wakeups.perform_wakeup(wakeup.id,
               now: ManualClock.now(),
               clock: ManualClock,
               observe: fn -> {:ok, snapshot} end
             )

    assert summary.branch == :admitted
    assert summary.dispatch.outcome == :dispatched

    cont_run_id = summary.dispatch.run_id
    assert cont_run_id != run.id

    # Continuation is populated from the wake checkpoint, not nil.
    new_run = Repo.get!(RunRecord, cont_run_id)
    assert new_run.continuation != nil
    assert new_run.continuation["checkpoint_id"] == wake_checkpoint_id(goal, run)
    assert is_binary(new_run.continuation["next_action"])
    assert is_list(new_run.continuation["decision_refs"])
    assert new_run.prompt == run.prompt

    # Provider identity follows the suspended run, not a default.
    assert new_run.provider_id == run.provider_id

    # The new run holds its own lease against the fresh snapshot.
    new_grant = Repo.get_by!(ExecutionLeaseRecord, run_id: cont_run_id)
    assert new_grant.status == "active"
    assert new_grant.admitted_snapshot_id == snapshot.snapshot_id
    assert new_grant.extensions["cobbler.lease:wakeup_id"] == wakeup.id
    assert is_binary(new_grant.extensions["cobbler.lease:admission_decision_id"])
  end

  test "codex provider run dispatches under the codex identity" do
    %{goal: goal, run: run} = wake_fixture("cmd-wake-codex")
    set_provider!(run, "codex_app_server_stdio")
    snapshot = eligible_snapshot!()
    wakeup = schedule_wake!(goal, run, "cmd-wake-codex")

    assert {:ok, summary} =
             Wakeups.perform_wakeup(wakeup.id,
               now: ManualClock.now(),
               clock: ManualClock,
               observe: fn -> {:ok, snapshot} end
             )

    assert summary.branch == :admitted
    new_run = Repo.get!(RunRecord, summary.dispatch.run_id)
    assert new_run.provider_id == "codex_app_server_stdio"
  end

  test "unknown provider fails closed with no continuation dispatch" do
    %{goal: goal, run: run} = wake_fixture("cmd-wake-unknown")
    set_provider!(run, "not-a-provider")
    snapshot = eligible_snapshot!()
    wakeup = schedule_wake!(goal, run, "cmd-wake-unknown")

    assert {:error, {:unknown_provider, "not-a-provider"}} =
             Wakeups.perform_wakeup(wakeup.id,
               now: ManualClock.now(),
               clock: ManualClock,
               observe: fn -> {:ok, snapshot} end
             )

    # Setup delivery only; the wake added nothing.
    assert Repo.aggregate(Shoestring.Harness.DispatchRecord, :count, :dispatch_id) == 1
    assert Repo.get!(WakeupRecord, wakeup.id).status != "woken"
  end

  test "existing checkpoint projects without writing a second one" do
    %{goal: goal, run: run} = wake_fixture("cmd-wake-existing")
    seed_checkpoint!(goal, run)
    snapshot = eligible_snapshot!()
    wakeup = schedule_wake!(goal, run, "cmd-wake-existing")

    assert {:ok, summary} =
             Wakeups.perform_wakeup(wakeup.id,
               now: ManualClock.now(),
               clock: ManualClock,
               observe: fn -> {:ok, snapshot} end
             )

    assert summary.branch == :admitted
    assert Repo.aggregate(CheckpointRecord, :count, :id) == 1

    new_run = Repo.get!(RunRecord, summary.dispatch.run_id)
    seeded = Repo.get_by!(CheckpointRecord, run_id: run.id)
    assert new_run.continuation["checkpoint_id"] == seeded.id
  end

  test "lost claim fails the wake before dispatch" do
    %{goal: goal, run: run} = wake_fixture("cmd-wake-noclaim")
    release_claims!(goal)
    snapshot = eligible_snapshot!()
    wakeup = schedule_wake!(goal, run, "cmd-wake-noclaim")

    assert {:error, {:wakeup_claim_lost, _reason}} =
             Wakeups.perform_wakeup(wakeup.id,
               now: ManualClock.now(),
               clock: ManualClock,
               observe: fn -> {:ok, snapshot} end
             )

    assert Repo.aggregate(Shoestring.Harness.DispatchRecord, :count, :dispatch_id) == 1
    assert Repo.get!(WakeupRecord, wakeup.id).status != "woken"
  end

  test "retry after grant reuses the run and the grant" do
    %{goal: goal, run: run} = wake_fixture("cmd-wake-retry")
    snapshot = eligible_snapshot!()
    wakeup = schedule_wake!(goal, run, "cmd-wake-retry")
    opts = [now: ManualClock.now(), clock: ManualClock, observe: fn -> {:ok, snapshot} end]

    assert {:ok, first} = Wakeups.perform_wakeup(wakeup.id, opts)

    # Simulate a crash between grant and the woken mark.
    Repo.update_all(
      from(w in WakeupRecord, where: w.id == ^wakeup.id),
      set: [status: "due"]
    )

    assert {:ok, second} = Wakeups.perform_wakeup(wakeup.id, opts)
    assert second.dispatch.run_id == first.dispatch.run_id

    new_run_id = first.dispatch.run_id

    assert Repo.aggregate(
             from(g in ExecutionLeaseRecord, where: g.run_id == ^new_run_id),
             :count,
             :id
           ) == 1

    assert Repo.aggregate(Shoestring.Harness.DispatchRecord, :count, :dispatch_id) == 2
  end

  test "wake persists its re-evaluation as admission.decided and converges retries" do
    %{goal: goal, run: run} = wake_fixture("cmd-wake-decision")
    snapshot = eligible_snapshot!()
    wakeup = schedule_wake!(goal, run, "cmd-wake-decision")
    opts = [now: ManualClock.now(), clock: ManualClock, observe: fn -> {:ok, snapshot} end]

    assert {:ok, first} = Wakeups.perform_wakeup(wakeup.id, opts)

    # The fixture setup appended one decision; the wake persists exactly one
    # more under its own idempotency key.
    decided =
      TrajectoryEvent
      |> where([e], e.goal_id == ^goal.id and e.type == "admission.decided")
      |> Repo.all()

    assert length(decided) == 2
    wake_decision = Enum.find(decided, &(&1.payload["decision_id"] == first.decision_id))
    assert wake_decision.payload["result"] == "admit"

    # A retry replays the same decision instead of minting a second one.
    Repo.update_all(
      from(w in WakeupRecord, where: w.id == ^wakeup.id),
      set: [status: "due"]
    )

    assert {:ok, second} = Wakeups.perform_wakeup(wakeup.id, opts)
    assert second.decision_id == first.decision_id

    assert TrajectoryEvent
           |> where([e], e.goal_id == ^goal.id and e.type == "admission.decided")
           |> Repo.aggregate(:count, :id) == 2
  end

  test "decline-produced sleep recovers on restored capacity" do
    %{goal: goal, run: run, grant_id: grant_id} = wake_fixture("cmd-wake-decline")
    snapshot = eligible_snapshot!()
    wakeup = schedule_wake!(goal, run, "cmd-wake-decline")

    # Drive the old lease to checkpoint_required the way a decline would
    # (transitions append events; rows advance on projection).
    assert {:ok, _} = Leases.transition(goal.id, grant_id, :renewal_due, repo: Repo)
    assert {:ok, _} = Projector.project(goal.id)
    assert {:ok, _} = Leases.transition(goal.id, grant_id, :expire, repo: Repo)
    assert {:ok, _} = Projector.project(goal.id)

    assert {:ok, _} =
             Leases.transition(goal.id, grant_id, :require_checkpoint, repo: Repo)

    assert {:ok, _} = Projector.project(goal.id)

    assert Repo.get!(ExecutionLeaseRecord, grant_id).status == "checkpoint_required"

    assert {:ok, summary} =
             Wakeups.perform_wakeup(wakeup.id,
               now: ManualClock.now(),
               clock: ManualClock,
               observe: fn -> {:ok, snapshot} end
             )

    assert summary.branch == :admitted
    assert summary.lease == :superseded
    # Old allowance rests terminal; the new run carries the fresh grant.
    assert Repo.get!(ExecutionLeaseRecord, grant_id).status == "checkpoint_required"

    new_grant = Repo.get_by!(ExecutionLeaseRecord, run_id: summary.dispatch.run_id)
    assert new_grant.status == "active"
    assert new_grant.admitted_snapshot_id == snapshot.snapshot_id
  end

  # ----------------------------------------------------------------------------
  # Fixtures
  # ----------------------------------------------------------------------------

  defp wake_fixture(command_id) do
    goal = create_goal!(Repo, "Wake continuation goal")
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

    %{goal: goal, task: task, run: Repo.get!(RunRecord, run.id), grant_id: grant_id}
  end

  defp wake_checkpoint_id(goal, run) do
    Repo.get_by!(CheckpointRecord, run_id: run.id, goal_id: goal.id).id
  end

  defp set_provider!(run, provider_id) do
    Repo.update_all(
      from(r in RunRecord, where: r.id == ^run.id),
      set: [provider_id: provider_id]
    )

    :ok
  end

  defp release_claims!(goal) do
    Repo.update_all(
      from(c in TaskClaimRecord, where: c.goal_id == ^goal.id),
      set: [
        status: "released",
        released_by_command_id: "cmd-wake-test-release",
        release_reason: "test released the claim",
        released_at: ManualClock.now()
      ]
    )

    :ok
  end

  defp seed_checkpoint!(goal, run) do
    {:ok, checkpoint} =
      Shoestring.Harness.CheckpointFallback.build(%{
        checkpoint_id: Ecto.UUID.generate(),
        goal_id: goal.id,
        run_id: run.id,
        acceptance_criteria: ["seeded recovery context"],
        repository_revision: "seed-rev",
        evidence: ["seeded evidence"],
        decisions: [],
        unresolved_issues: [],
        stop_reason: "seeded",
        extensions: %{}
      })

    assert {:ok, _} =
             Shoestring.Harness.Checkpoints.record(goal.id, checkpoint,
               repo: Repo,
               now: ManualClock.now(),
               actor: "wakeup-test",
               writer_opts: []
             )

    assert {:ok, _} = Projector.project(goal.id, clock: ManualClock)
    :ok
  end

  defp insert_task!(goal) do
    %Shoestring.Trajectory.Task{}
    |> Shoestring.Trajectory.Task.changeset(%{"title" => "Wake continuation task"})
    |> Ecto.Changeset.put_change(:goal_id, goal.id)
    |> Repo.insert!()
  end

  defp grant_payload(snapshot_id, result, reason_code, opts \\ []) do
    Shoestring.Test.CobblerHelpers.admission_payload()
    |> Map.merge(%{
      "decision_id" => Keyword.get(opts, :decision_id, Ecto.UUID.generate()),
      "result" => result,
      "reason_code" => reason_code,
      "explanation" => "Wake continuation decision: #{reason_code}",
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

    {:ok, snapshot} = Shoestring.Harness.CapacitySnapshot.new(attrs, now: now)
    snapshot
  end
end
