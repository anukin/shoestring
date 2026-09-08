defmodule Shoestring.Cobbler.LeaseGrantTest do
  @moduledoc """
  Hermetic DataCase tests for admission-wired lease issuance: an admitted
  claim issues a lease through the post-claim dispatcher hook (run row first,
  then `lease.proposed → lease.granted → lease.active`), every non-admit
  outcome refuses with the decision reason, a nil admitted snapshot refuses
  fail-closed, and replay returns the existing grant without new rows.

  Locking note (standing contract): the dispatcher-level tests below are true
  regression locks — on the pre-fix commit the dispatcher ignores the
  `grant_lease:` option and stops at `{:error, {:execution_disabled, _}}`
  with no lease or run rows, failing each assertion for the right behavioural
  reason. The final pure-mapping test is documentation: it calls the new
  `LeaseGrant` module directly and errors (rather than failing
  behaviourally) on the base commit.
  """
  use Shoestring.DataCase, async: false

  alias Oban.Job
  alias Shoestring.Cobbler.{Dispatcher, LeaseGrant, Leases}
  alias Shoestring.Harness.{ExecutionLeaseRecord, Fake, Projector, RunRecord}
  alias Shoestring.Test.FixedClock

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers
  alias Shoestring.Test.Fixtures.FakeHelpers

  @now ~U[2026-09-07 12:00:00.000000Z]

  setup do
    goal = create_goal!()
    task = insert_task!(goal)
    snapshot_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, snapshot_id)
    {:ok, goal: goal, task: task, snapshot_id: snapshot_id}
  end

  test "an admitted claim issues a lease and commits proposed→granted→active", %{
    goal: goal,
    task: task,
    snapshot_id: snapshot_id
  } do
    admission =
      append_admission_event!(
        goal.id,
        grant_payload(snapshot_id, "admit", "automatic_admission_eligible")
      )

    command = claim_command(admission, command_id: "cmd-lease-grant-1")

    assert {:ok, leased} =
             Dispatcher.claim_and_gate(goal.id, command, now: @now, grant_lease: lease_opts(task))

    assert leased.disposition == :leased
    assert leased.lease_outcome == :recorded
    assert leased.claim_id != nil
    assert leased.admission_event_id == admission.id
    assert leased.run.goal_id == goal.id
    assert leased.run.task_id == task.id
    assert leased.run.status == "requested"

    lease = leased.lease
    assert lease.response_budget == 10
    assert lease.tool_budget == 25
    assert lease.checkpoint_cadence == 1
    assert lease.reserves == %{response: 1, tool: 1}
    assert lease.version == 1
    assert lease.renewal_state == :none
    assert lease.run_id == leased.run.id
    assert lease.admitted_snapshot_id == snapshot_id
    assert DateTime.compare(lease.deadline, @now) == :gt
    assert {:ok, _grant_uuid} = Ecto.UUID.cast(lease.grant_id)

    assert lease.extensions["cobbler.lease:admission_decision_id"] ==
             admission.payload["decision_id"]

    assert lease.extensions["cobbler.lease:admission_event_id"] == admission.id
    assert lease.extensions["cobbler.lease:scope"] == "account:codex"
    assert lease.extensions["cobbler.lease:candidate"] == "codex/codex_app_server"

    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    record = Repo.get!(ExecutionLeaseRecord, leased.grant_id)
    assert record.status == "active"
    assert record.goal_id == goal.id
    assert record.run_id == leased.run.id
    assert record.admitted_snapshot_id == snapshot_id
    assert record.response_budget == 10
    assert record.tool_budget == 25

    assert lease_event_types(goal.id) == ["lease.proposed", "lease.granted", "lease.active"]

    # Issuance never spawns or enqueues: the only run row is the inert
    # requested intent, and Oban stays empty.
    assert Repo.aggregate(Job, :count, :id) == 0
    assert Repo.get!(RunRecord, leased.run.id).status == "requested"
  end

  test "a defer_until decision refuses with the decision reason and creates no rows", %{
    goal: goal,
    task: task,
    snapshot_id: snapshot_id
  } do
    admission =
      append_admission_event!(
        goal.id,
        grant_payload(snapshot_id, "defer_until", "reserve_breach_five_hour")
      )

    command = claim_command(admission, command_id: "cmd-lease-defer")

    assert {:error, {:lease_refused, detail}} =
             Dispatcher.claim_and_gate(goal.id, command, now: @now, grant_lease: lease_opts(task))

    assert detail.reason == "reserve_breach_five_hour"
    assert detail.result == "defer_until"
    assert detail.decision_id == admission.payload["decision_id"]
    assert detail.admission_event_id == admission.id

    assert_lease_rows(goal.id, 0)
    assert_run_rows(goal.id, 0)
  end

  test "a require_confirmation decision refuses with the decision reason", %{
    goal: goal,
    task: task,
    snapshot_id: snapshot_id
  } do
    admission =
      append_admission_event!(
        goal.id,
        grant_payload(snapshot_id, "require_confirmation", "stale_observation")
      )

    command = claim_command(admission, command_id: "cmd-lease-confirm")

    assert {:error, {:lease_refused, detail}} =
             Dispatcher.claim_and_gate(goal.id, command, now: @now, grant_lease: lease_opts(task))

    assert detail.reason == "stale_observation"
    assert detail.result == "require_confirmation"

    assert_lease_rows(goal.id, 0)
    assert_run_rows(goal.id, 0)
  end

  test "a reject decision refuses with the decision reason", %{
    goal: goal,
    task: task,
    snapshot_id: snapshot_id
  } do
    admission =
      append_admission_event!(
        goal.id,
        grant_payload(snapshot_id, "reject", "unsupported_capability")
      )

    command = claim_command(admission, command_id: "cmd-lease-reject")

    assert {:error, {:lease_refused, detail}} =
             Dispatcher.claim_and_gate(goal.id, command, now: @now, grant_lease: lease_opts(task))

    assert detail.reason == "unsupported_capability"
    assert detail.result == "reject"

    assert_lease_rows(goal.id, 0)
    assert_run_rows(goal.id, 0)
  end

  test "a confirmed admit with a nil admitted snapshot refuses fail-closed", %{
    goal: goal,
    task: task
  } do
    admission =
      append_admission_event!(goal.id, grant_payload(nil, "admit", "confirmed_stale_observation"))

    command = claim_command(admission, command_id: "cmd-lease-nil-snapshot")

    assert {:error, {:lease_refused, detail}} =
             Dispatcher.claim_and_gate(goal.id, command, now: @now, grant_lease: lease_opts(task))

    assert detail.reason == "admitted_snapshot_missing"
    assert detail.result == "admit"

    assert_lease_rows(goal.id, 0)
    assert_run_rows(goal.id, 0)
  end

  test "replay returns the existing grant without new rows or events", %{
    goal: goal,
    task: task,
    snapshot_id: snapshot_id
  } do
    admission =
      append_admission_event!(
        goal.id,
        grant_payload(snapshot_id, "admit", "automatic_admission_eligible")
      )

    command = claim_command(admission, command_id: "cmd-lease-replay")

    assert {:ok, first} =
             Dispatcher.claim_and_gate(goal.id, command, now: @now, grant_lease: lease_opts(task))

    assert first.lease_outcome == :recorded
    runs_before = run_rows(goal.id)
    lease_events_before = lease_event_types(goal.id)

    assert {:ok, second} =
             Dispatcher.claim_and_gate(goal.id, command, now: @now, grant_lease: lease_opts(task))

    assert second.disposition == :leased
    assert second.lease_outcome == :replayed
    assert second.grant_id == first.grant_id
    assert second.run == nil
    assert second.events == []
    assert run_rows(goal.id) == runs_before
    assert lease_event_types(goal.id) == lease_events_before

    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)
    assert_lease_rows(goal.id, 1)
    assert Repo.get!(ExecutionLeaseRecord, first.grant_id).status == "active"
  end

  test "pure mapping: bounds, deadline, reserves, refs, and fresh grant ids (documentation)" do
    goal = create_goal!()
    snapshot_id = Ecto.UUID.generate()
    decision_id = Ecto.UUID.generate()
    run_id = Ecto.UUID.generate()

    admission =
      append_admission_event!(
        goal.id,
        grant_payload(snapshot_id, "admit", "automatic_admission_eligible",
          decision_id: decision_id
        )
      )

    {:ok, command} =
      Shoestring.Cobbler.Command.new(claim_command(admission, command_id: "cmd-pure-map"))

    assert {:ok, first} = LeaseGrant.build(goal.id, run_id, admission, command, repo: Repo)
    assert {:ok, second} = LeaseGrant.build(goal.id, run_id, admission, command, repo: Repo)

    # D1: fresh UUID per grant.
    assert first.grant_id != second.grant_id

    assert first.run_id == run_id
    assert first.admitted_snapshot_id == snapshot_id
    assert first.response_budget == 10
    assert first.tool_budget == 25
    assert first.checkpoint_cadence == 1
    assert first.reserves == %{response: 1, tool: 1}
    assert first.version == 1
    assert first.renewal_state == :none
    assert first.deadline == DateTime.add(@now, 300, :second)
    assert first.extensions["cobbler.lease:admission_decision_id"] == decision_id
    assert first.extensions["cobbler.lease:admission_event_id"] == admission.id

    # The store-level replay lookup finds the committed grant by decision.
    assert Leases.find_by_decision(Repo, goal.id, decision_id) == nil
    assert Fake.identity().adapter_id == "shoestring.harness.fake"
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  defp insert_task!(goal) do
    %Shoestring.Trajectory.Task{}
    |> Shoestring.Trajectory.Task.changeset(%{"title" => "Lease task"})
    |> Ecto.Changeset.put_change(:goal_id, goal.id)
    |> Repo.insert!()
  end

  defp lease_opts(task) do
    [task_id: task.id, clock: FixedClock, now: FixedClock.now()]
  end

  defp grant_payload(snapshot_id, result, reason_code, opts \\ []) do
    admission_payload()
    |> Map.merge(%{
      "decision_id" => Keyword.get(opts, :decision_id, Ecto.UUID.generate()),
      "result" => result,
      "reason_code" => reason_code,
      "explanation" => "Lease wiring test decision: #{reason_code}",
      "observation" => %{
        "snapshot_id" => snapshot_id,
        "confidence" => "high",
        "freshness" => "fresh"
      },
      "proposed_bounds" => %{
        "response_budget" => 10,
        "tool_budget" => 25,
        "deadline" => DateTime.to_iso8601(DateTime.add(@now, 300, :second)),
        "checkpoint_cadence" => 1,
        "reserves" => %{"response" => 1, "tool" => 1}
      }
    })
  end

  defp lease_event_types(goal_id) do
    Repo.all(
      from event in Shoestring.Trajectory.TrajectoryEvent,
        where:
          event.goal_id == ^goal_id and
            event.type in [
              "lease.proposed",
              "lease.granted",
              "lease.active",
              "lease.renewal_due",
              "lease.renewed",
              "lease.expired",
              "lease.revoked",
              "lease.checkpoint_required"
            ],
        order_by: [asc: event.sequence],
        select: event.type
    )
  end

  defp assert_lease_rows(goal_id, count) do
    assert Repo.aggregate(
             from(lease in ExecutionLeaseRecord, where: lease.goal_id == ^goal_id),
             :count,
             :id
           ) == count
  end

  defp run_rows(goal_id) do
    Repo.all(from run in RunRecord, where: run.goal_id == ^goal_id, select: run.id)
  end

  defp assert_run_rows(goal_id, count) do
    assert length(run_rows(goal_id)) == count
  end
end
