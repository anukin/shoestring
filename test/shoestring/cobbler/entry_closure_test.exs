defmodule Shoestring.Cobbler.EntryClosureTest do
  @moduledoc """
  Hermetic DataCase locks for loop-closure I1: after claim+grant the
  dispatcher starts work ONLY through the durable dispatch pipeline
  (dispatch record + Oban job + `dispatch.requested`), never a direct
  `Elves.start_run`; unadmitted direct starts are refused; and a held claim
  refuses a second dispatch visibly with no second enforcement mechanism.
  """
  use Shoestring.DataCase, async: false

  alias Oban.Job
  alias Shoestring.Cobbler.Dispatcher
  alias Shoestring.Elves
  alias Shoestring.Harness.{DispatchRecord, Fake, RunRecord}
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

  test "admitted flow creates claim, grant, then dispatch record and job in order", %{
    goal: goal,
    task: task,
    snapshot_id: snapshot_id
  } do
    admission =
      append_admission_event!(
        goal.id,
        grant_payload(snapshot_id, "admit", "automatic_admission_eligible")
      )

    command = claim_command(admission, command_id: "cmd-entry-close-1")

    assert {:ok, leased} =
             Dispatcher.claim_and_gate(goal.id, command,
               now: @now,
               clock: FixedClock,
               grant_lease: lease_opts(task)
             )

    assert leased.disposition == :leased
    assert leased.lease_outcome == :recorded
    assert leased.run.status == "requested"

    # The pipeline delivers durably: exactly one Oban job. (Asserted before
    # touching the result map so the base commit fails here behaviorally
    # with 0 jobs instead of on map shape.)
    assert Repo.aggregate(from(job in Job), :count, :id) == 1

    # Durable delivery exists: dispatch record + the one Oban job.
    assert %DispatchRecord{status: "requested"} = leased.dispatch
    assert leased.dispatch.run_id == leased.run.id
    assert leased.dispatch.goal_id == goal.id
    assert leased.job.args["dispatch_id"] == leased.dispatch.dispatch_id

    # Ordering: claim acquired < lease proposed < dispatch requested.
    sequences = event_sequences(goal.id)

    assert sequences["cobbler.claim.acquired"] < sequences["lease.proposed"]
    assert sequences["lease.proposed"] < sequences["dispatch.requested"]

    # Idempotency keys pin each stage to its durable identifier.
    assert event_key(goal.id, "dispatch.requested") ==
             "dispatch-requested:#{leased.dispatch.dispatch_id}"

    assert event_key(goal.id, "lease.proposed") == "lease-proposed:#{leased.grant_id}"

    assert event_key(goal.id, "cobbler.claim.acquired") ==
             "cobbler-claim-acquired:#{leased.claim_id}"
  end

  test "replay of the admitted command creates zero new rows, events, or jobs", %{
    goal: goal,
    task: task,
    snapshot_id: snapshot_id
  } do
    admission =
      append_admission_event!(
        goal.id,
        grant_payload(snapshot_id, "admit", "automatic_admission_eligible")
      )

    command = claim_command(admission, command_id: "cmd-entry-close-replay")

    assert {:ok, first} =
             Dispatcher.claim_and_gate(goal.id, command,
               now: @now,
               clock: FixedClock,
               grant_lease: lease_opts(task)
             )

    assert first.lease_outcome == :recorded

    # The first pass established durable delivery (fails behaviorally on
    # base, where the grant path enqueues nothing).
    assert Repo.aggregate(from(job in Job), :count, :id) == 1

    counts_before = table_counts(goal.id)

    assert {:ok, second} =
             Dispatcher.claim_and_gate(goal.id, command,
               now: @now,
               clock: FixedClock,
               grant_lease: lease_opts(task)
             )

    assert second.disposition == :leased
    assert second.lease_outcome == :replayed
    assert second.grant_id == first.grant_id
    assert second.run == nil
    assert second.events == []
    assert second.dispatch == nil
    assert second.job == nil
    assert table_counts(goal.id) == counts_before
  end

  test "unadmitted gated start_run is refused with exact reason and zero rows/jobs (documentation)" do
    # DOCUMENTATION (not a lock): the `require_cobbler_command` refusal
    # plumbing predates this slice, so this passes on the base commit too. It
    # pins the exact reason and the zero-side-effect contract the UI relies on.
    goal = create_goal!()
    task = insert_task!(goal)

    assert {:error, {:no_claimed_command, detail}} =
             Elves.start_run(
               run_request(goal, task),
               Fake.identity(),
               require_cobbler_command: true,
               clock: FixedClock,
               identifier: Shoestring.Test.FixedIdentifier
             )

    assert detail.goal_id == goal.id
    assert detail.reason == :no_active_claim
    refute Repo.exists?(from run in RunRecord, where: run.goal_id == ^goal.id)
    assert Repo.aggregate(from(job in Job), :count, :id) == 0
  end

  test "claim-held second dispatch is refused visibly with no second mechanism (documentation)" do
    # DOCUMENTATION (not a lock): the SQLite-enforced exclusive claim and its
    # visible `awaiting_operator` refusal predate this slice; P3 deliberately
    # adds no second enforcement mechanism, so this passes on base too.
    holder = create_goal!()
    holder_admission = append_admission_event!(holder.id)

    assert {:error, {:execution_disabled, _}} =
             Dispatcher.claim_and_gate(
               holder.id,
               claim_command(holder_admission, command_id: "cmd-entry-holder"),
               now: @now
             )

    contender = create_goal!()
    contender_admission = append_admission_event!(contender.id)

    assert {:ok, %{disposition: :awaiting_operator, detail: detail}} =
             Dispatcher.claim_and_gate(
               contender.id,
               claim_command(contender_admission, command_id: "cmd-entry-contender"),
               now: @now
             )

    assert detail.reason == "claim_held"
    assert detail.options == ["abandon"]
    assert Shoestring.Cobbler.Commands.active_claim([]).goal_id == holder.id
    refute Repo.exists?(from run in RunRecord, where: run.goal_id == ^contender.id)
    assert Repo.aggregate(from(job in Job), :count, :id) == 0

    # Same goal, second concurrent command: refused the same visible way.
    assert {:ok, %{disposition: :awaiting_operator}} =
             Dispatcher.claim_and_gate(
               holder.id,
               claim_command(holder_admission, command_id: "cmd-entry-holder-second"),
               now: @now
             )
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  defp insert_task!(goal) do
    %Shoestring.Trajectory.Task{}
    |> Shoestring.Trajectory.Task.changeset(%{"title" => "Entry closure task"})
    |> Ecto.Changeset.put_change(:goal_id, goal.id)
    |> Repo.insert!()
  end

  defp lease_opts(task) do
    [task_id: task.id, clock: FixedClock, now: FixedClock.now()]
  end

  defp run_request(goal, task) do
    assert {:ok, request} =
             Shoestring.Harness.RunRequest.new(%{
               version: 1,
               goal_id: goal.id,
               task_id: task.id,
               workspace_ref: "workspace/project",
               prompt: "Unadmitted direct start attempt.",
               policy: %{mode: "supervised"},
               requested_capabilities: [],
               dispatch_id: Ecto.UUID.generate(),
               extensions: %{}
             })

    request
  end

  defp grant_payload(snapshot_id, result, reason_code, opts \\ []) do
    admission_payload()
    |> Map.merge(%{
      "decision_id" => Keyword.get(opts, :decision_id, Ecto.UUID.generate()),
      "result" => result,
      "reason_code" => reason_code,
      "explanation" => "Entry closure test decision: #{reason_code}",
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

  defp event_sequences(goal_id) do
    Repo.all(
      from event in Shoestring.Trajectory.TrajectoryEvent,
        where:
          event.goal_id == ^goal_id and
            event.type in [
              "cobbler.claim.acquired",
              "lease.proposed",
              "dispatch.requested"
            ],
        order_by: [asc: event.sequence],
        select: {event.type, event.sequence}
    )
    |> Map.new()
  end

  defp event_key(goal_id, type) do
    Repo.one!(
      from event in Shoestring.Trajectory.TrajectoryEvent,
        where: event.goal_id == ^goal_id and event.type == ^type,
        order_by: [asc: event.sequence],
        select: event.idempotency_key,
        limit: 1
    )
  end

  defp table_counts(goal_id) do
    %{
      runs: Repo.aggregate(from(run in RunRecord, where: run.goal_id == ^goal_id), :count, :id),
      dispatches:
        Repo.aggregate(
          from(dispatch in DispatchRecord, where: dispatch.goal_id == ^goal_id),
          :count,
          :dispatch_id
        ),
      jobs: Repo.aggregate(from(job in Job), :count, :id),
      events:
        Repo.aggregate(
          from(event in Shoestring.Trajectory.TrajectoryEvent,
            where: event.goal_id == ^goal_id
          ),
          :count,
          :id
        )
    }
  end
end
