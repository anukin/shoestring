defmodule ShoestringWeb.CobblerPresentationPlanTest do
  @moduledoc """
  Hermetic tests for the narrow iteration-6 presentation override: an
  intermediate planned-task run completing must not show the overall goal
  complete. Unplanned goals fold exactly as before.
  """
  use ExUnit.Case, async: true

  alias ShoestringWeb.CobblerPresentation

  defp run_completed_timeline do
    [
      {0, {:admission_decision, :admit}},
      {1, {:command_outcome, :claimed}},
      {2, :dispatch_started},
      {3, {:run_terminal, :completed}}
    ]
  end

  defp run_failed_timeline do
    [
      {0, {:admission_decision, :admit}},
      {1, {:command_outcome, :claimed}},
      {2, :dispatch_started},
      {3, {:run_terminal, :failed}}
    ]
  end

  test "an unplanned goal still shows a completed run as complete" do
    assert CobblerPresentation.derive_goal_state(run_completed_timeline()) == :completed

    assert CobblerPresentation.derive_goal_state_for_plan(run_completed_timeline(), :unplanned) ==
             :completed
  end

  test "an intermediate planned-task completion holds at working, not complete" do
    assert CobblerPresentation.derive_goal_state_for_plan(
             run_completed_timeline(),
             :planned_incomplete
           ) ==
             :working
  end

  test "an intermediate planned-task failure holds at working, not failed" do
    assert CobblerPresentation.derive_goal_state(run_failed_timeline()) == :failed

    assert CobblerPresentation.derive_goal_state_for_plan(
             run_failed_timeline(),
             :planned_incomplete
           ) ==
             :working
  end

  test "a fully accepted plan completes normally" do
    assert CobblerPresentation.derive_goal_state_for_plan(
             run_completed_timeline(),
             :planned_complete
           ) ==
             :completed
  end

  # A completed or stopped plan's state comes from the executor, not the
  # timeline; only the statuses that fold the timeline are checked here.
  test "unknown timelines stay unknown where the timeline decides" do
    assert CobblerPresentation.derive_goal_state_for_plan(["bogus"], :planned_incomplete) ==
             :unknown

    assert CobblerPresentation.derive_goal_state_for_plan(["bogus"], :unplanned) == :unknown
  end

  # The events a two-task plan records, as the goal page replays them: the
  # plan executor's own events, then per task an admission, a claim, a run,
  # and the claim's release (recorded on the release command's accepted
  # event, whose result kind is the string "released").
  defp ev(sequence, type, payload \\ %{}),
    do: %Shoestring.Trajectory.TrajectoryEvent{sequence: sequence, type: type, payload: payload}

  defp two_task_plan_timeline do
    task = fn base, id ->
      [
        ev(base, "admission.decided", %{"result" => "admit"}),
        ev(base + 1, "cobbler.command.accepted", %{
          "command_type" => "task.claim",
          "to_status" => "resolved",
          "result" => %{"kind" => "claimed"}
        }),
        ev(base + 2, "cobbler.claim.acquired"),
        ev(base + 3, "cobbler.plan.task.dispatched", %{"plan_task_id" => id}),
        ev(base + 4, "run.starting"),
        ev(base + 5, "run.completed"),
        ev(base + 6, "cobbler.plan.task.accepted", %{"plan_task_id" => id}),
        ev(base + 7, "cobbler.command.accepted", %{
          "command_type" => "task.release",
          "to_status" => "resolved",
          "result" => %{"kind" => "released"}
        }),
        ev(base + 8, "cobbler.claim.released")
      ]
    end

    [ev(1, "cobbler.plan.revision.created"), ev(2, "cobbler.plan.approved")] ++
      task.(10, "first") ++ [ev(30, "cobbler.plan.decision.requested")] ++ task.(40, "second")
  end

  test "a planned goal's task after task folds to a known state, not unknown" do
    timeline = two_task_plan_timeline()

    # Between tasks the next one is being admitted again.
    assert CobblerPresentation.derive_goal_state_for_plan(timeline, :planned_incomplete) ==
             :evaluating

    # Mid-task it is working.
    assert CobblerPresentation.derive_goal_state_for_plan(
             Enum.take(timeline, 7),
             :planned_incomplete
           ) == :working

    # An unplanned goal folds exactly as before: one run's terminal is final.
    assert CobblerPresentation.derive_goal_state(timeline) == :unknown
  end

  test "a plan stopped for a person shows that, from the executor's state" do
    timeline = two_task_plan_timeline()

    assert CobblerPresentation.derive_goal_state_for_plan(timeline, :planned_needs_user) ==
             :plan_needs_user

    assert CobblerPresentation.derive_goal_state_for_plan(timeline, :planned_complete) ==
             :completed

    assert %{status: "plan-needs-user", label: "Needs you."} =
             CobblerPresentation.lifecycle_presentation(:plan_needs_user)
  end
end
