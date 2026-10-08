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

  test "unknown timelines stay unknown under every plan status" do
    assert CobblerPresentation.derive_goal_state_for_plan(["bogus"], :planned_incomplete) ==
             :unknown

    assert CobblerPresentation.derive_goal_state_for_plan(["bogus"], :unplanned) == :unknown
  end
end
