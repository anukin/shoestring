defmodule ShoestringWeb.CobblerTimelineTest do
  @moduledoc """
  Unit tests for the sequence-ordered timeline derivation
  (`CobblerPresentation.derive_goal_state/1`): out-of-order inputs fold in
  sequence order, run progress mid-list contributes working/checkpointing
  signal and outcome-carrying terminals, and unknown codes fold to
  `:unknown` without raising.

  Locking note (standing contract): `derive_goal_state/1` is new surface
  in this slice, so on the pre-fix commit `85437ed` every timeline test
  below fails with `UndefinedFunctionError` — DOCUMENTATION, not a
  behavior-change lock. The true behavior-change locks for this slice are
  the LiveView terminal/handoff tests (a finished run keeps its outcome
  class instead of recycling to `:evaluating`). The legacy grouped
  `derive_goal_state/2` twins pass on both commits and are labeled as
  preserved behavior.
  """
  use ExUnit.Case, async: true

  alias ShoestringWeb.CobblerPresentation

  defp decision(sequence, result),
    do: %{sequence: sequence, kind: :decision, value: result}

  defp command(sequence, kind),
    do: %{sequence: sequence, kind: :command, value: kind}

  defp run(sequence, code),
    do: %{sequence: sequence, kind: :run, value: code}

  test "out-of-order input sequences still fold in sequence order" do
    ordered = [
      decision(1, "admit"),
      command(2, "claimed"),
      run(3, "run.running")
    ]

    assert CobblerPresentation.derive_goal_state(ordered) == :working
    assert CobblerPresentation.derive_goal_state(Enum.shuffle(ordered)) == :working
    assert CobblerPresentation.derive_goal_state(Enum.reverse(ordered)) == :working
  end

  test "run progress mid-list contributes working then checkpointing signal" do
    timeline = [
      decision(1, "admit"),
      command(2, "claimed"),
      run(3, "run.running"),
      run(4, "checkpoint.created")
    ]

    assert CobblerPresentation.derive_goal_state(timeline) == :checkpointing
    assert CobblerPresentation.derive_goal_state(Enum.reverse(timeline)) == :checkpointing
  end

  test "run completion mid-list lands the outcome class instead of recycling" do
    completed = [
      decision(1, "admit"),
      command(2, "claimed"),
      run(3, "run.running"),
      run(4, "run.completed")
    ]

    failed = [
      decision(1, "admit"),
      command(2, "claimed"),
      run(3, "run.running"),
      run(4, "checkpoint.created"),
      run(5, "run.failed")
    ]

    interrupted = [
      decision(1, "admit"),
      command(2, "claimed"),
      run(3, "run.running"),
      run(4, "run.interrupted")
    ]

    assert CobblerPresentation.derive_goal_state(completed) == :completed
    assert CobblerPresentation.derive_goal_state(failed) == :failed
    # Outcome-less run ends keep the legacy evaluating recycle.
    assert CobblerPresentation.derive_goal_state(interrupted) == :evaluating
  end

  test "suspension mid-run folds to sleeping without new writes" do
    timeline = [
      decision(1, "admit"),
      command(2, "claimed"),
      run(3, "run.running"),
      run(4, "run.suspended")
    ]

    assert CobblerPresentation.derive_goal_state(timeline) == :sleeping
  end

  test "handoff mid-list hands off; completed stays terminal against later events" do
    handoff = [
      decision(1, "admit"),
      command(2, "claimed"),
      run(3, "handoff.created")
    ]

    assert CobblerPresentation.derive_goal_state(handoff) == :handing_off

    terminal_then_more = [
      decision(1, "admit"),
      command(2, "claimed"),
      run(3, "run.running"),
      run(4, "run.completed"),
      decision(5, "admit")
    ]

    assert CobblerPresentation.derive_goal_state(terminal_then_more) == :unknown
  end

  test "unknown codes fold to unknown, never raise" do
    assert CobblerPresentation.derive_goal_state([decision(1, "future_result")]) == :unknown
    assert CobblerPresentation.derive_goal_state([run(1, "run.warped")]) == :unknown

    assert CobblerPresentation.derive_goal_state([
             decision(1, "admit"),
             command(2, "future_kind")
           ]) == :unknown

    assert CobblerPresentation.derive_goal_state([%{kind: :bogus, value: 1}]) == :unknown
    assert CobblerPresentation.derive_goal_state("nope") == :unknown
    assert CobblerPresentation.derive_goal_state(nil) == :unknown
  end

  test "lifecycle-irrelevant event structs are skipped, not folded to unknown" do
    lease_event = %Shoestring.Trajectory.TrajectoryEvent{
      id: Ecto.UUID.generate(),
      goal_id: Ecto.UUID.generate(),
      sequence: 3,
      type: "lease.proposed",
      payload: %{},
      actor: "cobbler",
      occurred_at: ~U[2026-09-07 12:00:00.000000Z]
    }

    admit_event = %Shoestring.Trajectory.TrajectoryEvent{
      id: Ecto.UUID.generate(),
      goal_id: Ecto.UUID.generate(),
      sequence: 2,
      type: "admission.decided",
      payload: %{"result" => "admit"},
      actor: "cobbler",
      occurred_at: ~U[2026-09-07 12:00:00.000000Z]
    }

    assert CobblerPresentation.derive_goal_state([admit_event, lease_event]) == :queued
  end

  test "legacy grouped derivation twins are preserved" do
    assert CobblerPresentation.derive_goal_state(["admit"], []) == :queued
    assert CobblerPresentation.derive_goal_state(["admit"], ["claimed"]) == :dispatching
    assert CobblerPresentation.derive_goal_state(["admit"], ["needs_user"]) == :queued
    assert CobblerPresentation.derive_goal_state(["future_result"], []) == :unknown
  end

  test "new terminal states keep distinct status tags" do
    statuses =
      [
        :evaluating,
        :queued,
        :dispatching,
        :working,
        :checkpointing,
        :sleeping,
        :completed,
        :failed,
        :needs_user,
        :handing_off
      ]
      |> Enum.map(&CobblerPresentation.lifecycle_presentation(&1).status)

    assert length(Enum.uniq(statuses)) == length(statuses)
  end
end
