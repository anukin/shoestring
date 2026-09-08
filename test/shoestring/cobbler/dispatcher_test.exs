defmodule Shoestring.Cobbler.DispatcherTest do
  @moduledoc """
  Hermetic DataCase tests for the first gated dispatch consumer: commands
  are read back, the admission reference and claim ownership are
  re-validated, identical replays re-gate without new effects, conflicting
  reuse is rejected, held claims wait for the operator, and validated claims
  stop at the explicit execution-disabled boundary (no processes, no jobs).
  """
  use Shoestring.DataCase, async: false

  alias Oban.Job
  alias Shoestring.Cobbler.Commands
  alias Shoestring.Cobbler.Dispatcher

  import Shoestring.Test.CobblerHelpers

  @now ~U[2026-09-07 12:00:00.000000Z]

  setup do
    goal = create_goal!()
    {:ok, goal: goal}
  end

  test "a claimed command stops at the execution-disabled boundary", %{goal: goal} do
    admission = append_admission_event!(goal.id)
    command = claim_command(admission, command_id: "cmd-dispatch-1")

    assert {:error, {:execution_disabled, detail}} =
             Dispatcher.claim_and_gate(goal.id, command, now: @now)

    assert detail.boundary == "execution_disabled"
    assert detail.goal_id == goal.id
    assert detail.command_id == "cmd-dispatch-1"
    assert detail.outcome == :recorded
    assert is_binary(detail.claim_id)
    assert detail.admission_event_id == admission.id

    # Boundary proof: no process was spawned by us, no job was enqueued.
    assert Repo.aggregate(Job, :count, :id) == 0
  end

  test "identical replay re-gates without new events or claims", %{goal: goal} do
    admission = append_admission_event!(goal.id)
    command = claim_command(admission, command_id: "cmd-dispatch-replay")

    assert {:error, {:execution_disabled, first}} =
             Dispatcher.claim_and_gate(goal.id, command, now: @now)

    events_before = cobbler_events(goal.id)

    assert {:error, {:execution_disabled, second}} =
             Dispatcher.claim_and_gate(goal.id, command, now: @now)

    assert second.outcome == :replayed
    assert second.claim_id == first.claim_id
    assert cobbler_events(goal.id) == events_before
    assert Repo.aggregate(Job, :count, :id) == 0
  end

  test "conflicting reuse of a command id is rejected through the consumer", %{
    goal: goal
  } do
    admission = append_admission_event!(goal.id)
    command = claim_command(admission, command_id: "cmd-dispatch-conflict")

    assert {:error, {:execution_disabled, _detail}} =
             Dispatcher.claim_and_gate(goal.id, command, now: @now)

    conflicting =
      command
      |> put_in(["payload", "scope"], "account:other")
      |> put_in(["payload", "admission_event_id"], admission.id)

    events_before = cobbler_events(goal.id)

    assert {:error, {:command_conflict, conflict}} =
             Dispatcher.claim_and_gate(goal.id, conflicting, now: @now)

    assert conflict["command_id"] == "cmd-dispatch-conflict"
    assert conflict["existing_digest"] != conflict["incoming_digest"]
    assert cobbler_events(goal.id) == events_before
  end

  test "a held claim waits for the operator instead of dispatching", %{goal: goal} do
    holder = create_goal!()
    holder_admission = append_admission_event!(holder.id)

    assert {:error, {:execution_disabled, _}} =
             Dispatcher.claim_and_gate(
               holder.id,
               claim_command(holder_admission, command_id: "cmd-dispatch-holder"),
               now: @now
             )

    admission = append_admission_event!(goal.id)

    assert {:ok, %{disposition: :awaiting_operator, outcome: :recorded, detail: detail}} =
             Dispatcher.claim_and_gate(
               goal.id,
               claim_command(admission, command_id: "cmd-dispatch-held"),
               now: @now
             )

    assert detail.reason == "claim_held"
    assert detail.options == ["abandon"]
    # The holder still owns the only active claim.
    assert Commands.active_claim([]).goal_id == holder.id
  end

  test "dispatch/3 rejects rows without a live owned claim", %{goal: goal} do
    assert {:error, :command_not_found} = Dispatcher.dispatch(goal.id, "cmd-missing", [])

    holder = create_goal!()
    holder_admission = append_admission_event!(holder.id)

    assert {:error, {:execution_disabled, _}} =
             Dispatcher.claim_and_gate(
               holder.id,
               claim_command(holder_admission, command_id: "cmd-dispatch-owner"),
               now: @now
             )

    admission = append_admission_event!(goal.id)

    assert {:ok, %{disposition: :awaiting_operator}} =
             Dispatcher.claim_and_gate(
               goal.id,
               claim_command(admission, command_id: "cmd-dispatch-waiter"),
               now: @now
             )

    assert {:error, {:no_claimed_command, detail}} =
             Dispatcher.dispatch(goal.id, "cmd-dispatch-waiter", [])

    assert detail.disposition == :awaiting_operator
  end

  test "dispatch/3 gates a live owned claim at the disabled boundary", %{goal: goal} do
    admission = append_admission_event!(goal.id)

    assert {:error, {:execution_disabled, _}} =
             Dispatcher.claim_and_gate(
               goal.id,
               claim_command(admission, command_id: "cmd-dispatch-live"),
               now: @now
             )

    assert {:error, {:execution_disabled, detail}} =
             Dispatcher.dispatch(goal.id, "cmd-dispatch-live", [])

    assert detail.command_id == "cmd-dispatch-live"
    assert detail.goal_id == goal.id
  end

  defp cobbler_events(goal_id) do
    Repo.all(
      from event in Shoestring.Trajectory.TrajectoryEvent,
        where:
          event.goal_id == ^goal_id and
            event.type in [
              "cobbler.command.accepted",
              "cobbler.command.resolved",
              "cobbler.claim.acquired",
              "cobbler.claim.released"
            ],
        order_by: [asc: event.sequence],
        select: {event.sequence, event.type, event.idempotency_key}
    )
  end
end
