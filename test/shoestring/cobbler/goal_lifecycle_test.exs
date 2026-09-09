defmodule Shoestring.Cobbler.GoalLifecycleTest do
  @moduledoc """
  Pure unit tests for the goal-level lifecycle machine. No database, no
  processes: transitions are driven by admission decisions and command
  outcomes only.
  """
  use ExUnit.Case, async: true

  alias Shoestring.Cobbler.GoalLifecycle

  test "initial state is evaluating and completed/failed/handing_off are terminal" do
    assert GoalLifecycle.initial() == :evaluating
    assert GoalLifecycle.terminal?(:handing_off)
    assert GoalLifecycle.terminal?(:completed)
    assert GoalLifecycle.terminal?(:failed)
    refute GoalLifecycle.terminal?(:needs_user)

    for state <- GoalLifecycle.states() -- [:handing_off, :completed, :failed] do
      refute GoalLifecycle.terminal?(state)
    end
  end

  test "admit moves evaluating to queued; defer parks in sleeping" do
    assert GoalLifecycle.transition(:evaluating, {:admission_decision, :admit}) ==
             {:ok, :queued}

    assert GoalLifecycle.transition(:evaluating, {:admission_decision, :defer_until}) ==
             {:ok, :sleeping}
  end

  test "require_confirmation waits in evaluating; reject hands off" do
    assert GoalLifecycle.transition(:evaluating, {:admission_decision, :require_confirmation}) ==
             {:ok, :evaluating}

    assert GoalLifecycle.transition(:evaluating, {:admission_decision, :reject}) ==
             {:ok, :handing_off}
  end

  test "claimed moves queued to dispatching; held claims wait recoverably" do
    assert GoalLifecycle.transition(:queued, {:command_outcome, :claimed}) ==
             {:ok, :dispatching}

    assert GoalLifecycle.transition(:queued, {:command_outcome, :needs_user}) ==
             {:ok, :queued}
  end

  test "rejected or abandoned commands return the goal to evaluating" do
    assert GoalLifecycle.transition(:queued, {:command_outcome, :rejected}) ==
             {:ok, :evaluating}

    assert GoalLifecycle.transition(:queued, {:command_outcome, :abandoned}) ==
             {:ok, :evaluating}
  end

  test "dispatch_blocked waits at the gate instead of bypassing it" do
    assert GoalLifecycle.transition(:dispatching, :dispatch_blocked) == {:ok, :dispatching}
    assert GoalLifecycle.transition(:dispatching, :dispatch_started) == {:ok, :working}
  end

  test "checkpoint cycles inside a run; terminal runs re-enter evaluation" do
    assert GoalLifecycle.transition(:working, :checkpoint_started) == {:ok, :checkpointing}
    assert GoalLifecycle.transition(:checkpointing, :checkpoint_done) == {:ok, :working}
    assert GoalLifecycle.transition(:working, :run_terminal) == {:ok, :evaluating}
    assert GoalLifecycle.transition(:checkpointing, :run_terminal) == {:ok, :evaluating}
  end

  test "sleeping wakes only on an explicit recheck" do
    assert GoalLifecycle.transition(:sleeping, :recheck_due) == {:ok, :evaluating}
    assert GoalLifecycle.transition(:sleeping, {:admission_decision, :admit}) == {:ok, :queued}
  end

  test "handoff is reachable from every live state and is terminal" do
    for state <- [:evaluating, :queued, :dispatching, :working, :checkpointing, :sleeping] do
      assert GoalLifecycle.transition(state, :handoff_requested) == {:ok, :handing_off},
             "expected handoff from #{state}"
    end

    for event <- [:recheck_due, :run_terminal, :dispatch_started, :handoff_requested] do
      assert {:error, {:invalid_transition, :handing_off, ^event}} =
               GoalLifecycle.transition(:handing_off, event)
    end
  end

  test "illegal transitions are rejected, never coerced" do
    assert {:error, {:invalid_transition, :evaluating, {:command_outcome, :claimed}}} =
             GoalLifecycle.transition(:evaluating, {:command_outcome, :claimed})

    assert {:error, {:invalid_transition, :queued, :dispatch_started}} =
             GoalLifecycle.transition(:queued, :dispatch_started)

    assert {:error, {:invalid_transition, :working, {:command_outcome, :claimed}}} =
             GoalLifecycle.transition(:working, {:command_outcome, :claimed})

    assert {:error, {:invalid_transition, :dispatching, :recheck_due}} =
             GoalLifecycle.transition(:dispatching, :recheck_due)
  end

  test "a full admit -> claim -> gate -> work -> terminal walk" do
    assert {:ok, :queued} = GoalLifecycle.transition(:evaluating, {:admission_decision, :admit})
    assert {:ok, :dispatching} = GoalLifecycle.transition(:queued, {:command_outcome, :claimed})
    assert {:ok, :dispatching} = GoalLifecycle.transition(:dispatching, :dispatch_blocked)
    assert {:ok, :working} = GoalLifecycle.transition(:dispatching, :dispatch_started)
    assert {:ok, :checkpointing} = GoalLifecycle.transition(:working, :checkpoint_started)
    assert {:ok, :working} = GoalLifecycle.transition(:checkpointing, :checkpoint_done)
    assert {:ok, :evaluating} = GoalLifecycle.transition(:working, :run_terminal)
  end
end
