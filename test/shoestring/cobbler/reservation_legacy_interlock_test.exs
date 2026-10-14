defmodule Shoestring.Cobbler.ReservationLegacyInterlockTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.Cobbler.{Commands, Dispatcher, ReservationPolicy, Reservations}
  alias Shoestring.Test.{CobblerHelpers, PlanExecutorHelpers, ReservationHelpers}
  @now PlanExecutorHelpers.now()

  test "an unresolved reservation blocks a new unrelated legacy claim" do
    fixture = ReservationHelpers.fixture(:orphan)
    other = CobblerHelpers.create_goal!()
    admission = PlanExecutorHelpers.admit!(other)

    assert {:ok, %{command: %{status: "rejected", result: result}}} =
             Commands.submit(other.id, CobblerHelpers.claim_command(admission), now: @now)

    assert result["reason"] == "reservation_ownership_held"
    assert Commands.active_claim() == nil
    assert Reservations.outstanding() == [fixture.owner]
  end

  test "an active legacy claim blocks a new foreign reservation" do
    fixture = ReservationHelpers.fixture(:orphan)
    # Release only this provably unstarted fixture reservation, then acquire a
    # legacy owner before attempting the new hold in the opposite order.
    assert {:ok, %{settlement: %{kind: "released"}}} = Reservations.reconcile(fixture.owner.id)
    other = CobblerHelpers.create_goal!()
    admission = PlanExecutorHelpers.admit!(other)

    assert {:ok, _} =
             Commands.submit(other.id, CobblerHelpers.claim_command(admission), now: @now)

    claim = Commands.active_claim()
    {:ok, policy} = ReservationPolicy.new()
    next_admission = PlanExecutorHelpers.admit!(fixture.goal)

    attrs = %{
      id: Ecto.UUID.generate(),
      goal_id: fixture.goal.id,
      execution_id: Ecto.UUID.generate(),
      plan_task_id: "alpha",
      attempt: 2,
      run_id: Ecto.UUID.generate(),
      admission_event_id: next_admission.id
    }

    assert {:error, {:reservation_blocked, :legacy_claim}} =
             Reservations.hold(attrs, policy, now: @now)

    assert Commands.active_claim() == claim
    assert Reservations.outstanding() == []
  end

  test "a replayed legacy claim cannot bypass newly held reservation ownership" do
    fixture = ReservationHelpers.fixture(:orphan)
    assert {:ok, %{settlement: %{kind: "released"}}} = Reservations.reconcile(fixture.owner.id)
    admission = PlanExecutorHelpers.admit!(fixture.goal)
    attrs = CobblerHelpers.claim_command(admission)
    assert {:ok, _} = Commands.submit(fixture.goal.id, attrs, now: @now)
    next_admission = PlanExecutorHelpers.admit!(fixture.goal)
    {:ok, policy} = ReservationPolicy.new()

    owner = %{
      id: Ecto.UUID.generate(),
      goal_id: fixture.goal.id,
      execution_id: Ecto.UUID.generate(),
      plan_task_id: "beta",
      attempt: 1,
      run_id: Ecto.UUID.generate(),
      admission_event_id: next_admission.id
    }

    assert {:ok, _} = Reservations.hold(owner, policy, now: @now)

    assert {:error, :reservation_ownership_held} =
             Dispatcher.claim_and_gate(fixture.goal.id, attrs)
  end
end
