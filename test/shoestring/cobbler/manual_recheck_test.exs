defmodule Shoestring.Cobbler.ManualRecheckTest do
  @moduledoc """
  Hermetic DataCase tests for the explicit operator recheck (P6): operator
  identity is required (anonymous calls fail), terminal and handed-off goals
  are rejected, and a live goal gets an immediate due wake.

  Locking note (standing contract): manual recheck is new surface in this
  slice, so on the pre-fix commit these tests error on the missing modules
  (documentation, not behavior-change locks). Stated honestly here rather
  than claimed as coverage.
  """
  use Shoestring.DataCase, async: false

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers

  alias Shoestring.Cobbler.{Wakeups, WakeupRecord}
  alias Shoestring.Test.ManualClock

  @t0 ~U[2026-09-07 12:00:00.000000Z]

  setup do
    ManualClock.set(@t0)
    {:ok, goal: create_goal!()}
  end

  test "anonymous rechecks fail without scheduling anything", %{goal: goal} do
    assert {:error, :anonymous_operator} =
             Wakeups.request_recheck(goal.id, now: @t0, clock: ManualClock)

    assert {:error, :anonymous_operator} =
             Wakeups.request_recheck(goal.id,
               operator_identity: "  ",
               now: @t0,
               clock: ManualClock
             )

    assert wakeup_count(goal.id) == 0
  end

  test "a handed-off goal is rejected", %{goal: goal} do
    append_admission_event!(
      goal.id,
      admission_payload()
      |> Map.merge(%{
        "result" => "reject",
        "reason_code" => "unsupported_capability"
      })
    )

    assert Wakeups.lifecycle_state(Repo, goal.id) == :handing_off

    assert {:error, {:recheck_rejected, :handing_off}} =
             Wakeups.request_recheck(goal.id,
               operator_identity: "operator:alice",
               now: @t0,
               clock: ManualClock
             )

    assert wakeup_count(goal.id) == 0
  end

  test "a terminal goal is rejected", %{goal: goal} do
    append_admission_event!(goal.id)

    goal
    |> Ecto.Changeset.change(%{status: "completed"})
    |> Repo.update!()

    assert {:error, {:wakeup_rejected, :goal_terminal}} =
             Wakeups.request_recheck(goal.id,
               operator_identity: "operator:alice",
               now: @t0,
               clock: ManualClock
             )

    assert wakeup_count(goal.id) == 0
  end

  test "an unknown derivation fails closed", %{goal: goal} do
    # Two admits in a row cannot fold through the machine (queued + admit
    # is illegal), so derivation yields :unknown and the recheck refuses.
    append_admission_event!(goal.id)
    append_admission_event!(goal.id)

    assert Wakeups.lifecycle_state(Repo, goal.id) == :unknown

    assert {:error, {:recheck_rejected, :unknown_state}} =
             Wakeups.request_recheck(goal.id,
               operator_identity: "operator:alice",
               now: @t0,
               clock: ManualClock
             )

    assert wakeup_count(goal.id) == 0
  end

  test "a live goal gets an immediate due wake keyed by operator", %{goal: goal} do
    append_admission_event!(goal.id)

    assert {:ok, %{wakeup: wakeup, outcome: :recorded}} =
             Wakeups.request_recheck(goal.id,
               operator_identity: "operator:alice",
               now: @t0,
               clock: ManualClock
             )

    assert wakeup.status == "due"
    assert wakeup.reason == "manual_recheck"
    assert wakeup.idempotency_key == "wakeup:#{goal.id}:manual:operator:alice"
  end

  test "a sleeping goal accepts an operator recheck", %{goal: goal} do
    append_admission_event!(
      goal.id,
      admission_payload()
      |> Map.merge(%{
        "result" => "defer_until",
        "reason_code" => "reserve_breach_five_hour"
      })
    )

    assert Wakeups.lifecycle_state(Repo, goal.id) == :sleeping

    assert {:ok, %{wakeup: wakeup, outcome: :recorded}} =
             Wakeups.request_recheck(goal.id,
               operator_identity: "operator:alice",
               now: @t0,
               clock: ManualClock
             )

    assert wakeup.status == "due"
  end

  test "recheck without prior decisions fails closed", %{goal: _goal} do
    fresh = create_goal!()

    assert {:error, :missing_admission_context} =
             Wakeups.request_recheck(fresh.id,
               operator_identity: "operator:alice",
               now: @t0,
               clock: ManualClock
             )

    assert wakeup_count(fresh.id) == 0
  end

  defp wakeup_count(goal_id) do
    Repo.aggregate(from(w in WakeupRecord, where: w.goal_id == ^goal_id), :count, :id)
  end
end
