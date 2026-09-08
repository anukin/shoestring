defmodule Shoestring.Cobbler.GoalLifecycleSleepingTest do
  @moduledoc """
  Pure regression locks for the sleeping-state gap (P5): a sleeping goal
  waits in place on a repeat `defer_until` (resleep) or a
  `require_confirmation` (operator confirms out-of-band), and a claim
  released while sleeping returns the goal to evaluation.

  Locking note (standing contract): these are TRUE regression locks. On the
  pre-fix commit `d3ca088` the sleeping state accepts only
  `admit`/`reject`/`recheck_due`, so each test below fails for the right
  behavioural reason (`{:error, {:invalid_transition, :sleeping, _}}` where
  `{:ok, _}` is asserted).
  """
  use ExUnit.Case, async: true

  alias Shoestring.Cobbler.GoalLifecycle

  test "sleeping + defer_until waits in place (resleep)" do
    assert GoalLifecycle.transition(:sleeping, {:admission_decision, :defer_until}) ==
             {:ok, :sleeping}
  end

  test "sleeping + require_confirmation waits in place (operator surface preserved)" do
    assert GoalLifecycle.transition(:sleeping, {:admission_decision, :require_confirmation}) ==
             {:ok, :sleeping}
  end

  test "claim released while sleeping returns the goal to evaluating" do
    assert GoalLifecycle.transition(:sleeping, {:command_outcome, :released}) ==
             {:ok, :evaluating}
  end

  test "sleeping twins are preserved: admit queues, reject hands off, recheck evaluates" do
    assert GoalLifecycle.transition(:sleeping, {:admission_decision, :admit}) == {:ok, :queued}

    assert GoalLifecycle.transition(:sleeping, {:admission_decision, :reject}) ==
             {:ok, :handing_off}

    assert GoalLifecycle.transition(:sleeping, :recheck_due) == {:ok, :evaluating}
  end

  test "via decision structs: defer/confirm/reject apply to a sleeping goal" do
    assert GoalLifecycle.apply_decision(:sleeping, :defer_until) == {:ok, :sleeping}
    assert GoalLifecycle.apply_decision(:sleeping, :require_confirmation) == {:ok, :sleeping}
    assert GoalLifecycle.apply_decision(:sleeping, :reject) == {:ok, :handing_off}
  end
end
