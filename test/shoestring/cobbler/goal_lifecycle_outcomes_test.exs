defmodule Shoestring.Cobbler.GoalLifecycleOutcomesTest do
  @moduledoc """
  Regression locks for outcome-carrying run terminals (P1): `working` /
  `checkpointing` plus `{:run_terminal, outcome}` land in
  `completed` / `failed` / `needs_user`, while the bare `:run_terminal`
  keeps the legacy `:evaluating` recycle for outcome-less callers.

  Locking note (standing contract): the outcome-carrying tests are TRUE
  regression locks. On the pre-fix commit `85437ed` the machine accepts
  only the bare `:run_terminal` atom, so each outcome test below fails
  for the right behavioural reason (`{:error, {:invalid_transition, _,
  {:run_terminal, _}}}` where `{:ok, _}` is asserted). The bare-recycle
  twins pass on both commits and are labeled as preserved behavior, not
  locks.
  """
  use ExUnit.Case, async: true

  alias Shoestring.Cobbler.GoalLifecycle

  test "working + outcome-carrying terminals land completed/failed/needs_user" do
    assert GoalLifecycle.transition(:working, {:run_terminal, :completed}) ==
             {:ok, :completed}

    assert GoalLifecycle.transition(:working, {:run_terminal, :failed}) == {:ok, :failed}

    assert GoalLifecycle.transition(:working, {:run_terminal, :needs_user}) ==
             {:ok, :needs_user}
  end

  test "checkpointing + outcome-carrying terminals land completed/failed/needs_user" do
    assert GoalLifecycle.transition(:checkpointing, {:run_terminal, :completed}) ==
             {:ok, :completed}

    assert GoalLifecycle.transition(:checkpointing, {:run_terminal, :failed}) ==
             {:ok, :failed}

    assert GoalLifecycle.transition(:checkpointing, {:run_terminal, :needs_user}) ==
             {:ok, :needs_user}
  end

  test "outcome-less terminals preserve the legacy evaluating recycle (twins)" do
    assert GoalLifecycle.transition(:working, :run_terminal) == {:ok, :evaluating}
    assert GoalLifecycle.transition(:checkpointing, :run_terminal) == {:ok, :evaluating}
  end

  test "run_terminal_event maps outcome atoms and strings, rejects unknowns" do
    assert GoalLifecycle.run_terminal_event(:completed) == {:ok, {:run_terminal, :completed}}
    assert GoalLifecycle.run_terminal_event("failed") == {:ok, {:run_terminal, :failed}}
    assert GoalLifecycle.run_terminal_event("needs_user") == {:ok, {:run_terminal, :needs_user}}
    assert {:error, {:unknown_run_outcome, _}} = GoalLifecycle.run_terminal_event("bogus")
    assert {:error, {:unknown_run_outcome, :bogus}} = GoalLifecycle.run_terminal_event(:bogus)
  end

  test "outcome-carrying terminals are rejected outside working/checkpointing" do
    for state <- [:evaluating, :queued, :dispatching, :sleeping, :needs_user] do
      assert {:error, {:invalid_transition, ^state, {:run_terminal, :completed}}} =
               GoalLifecycle.transition(state, {:run_terminal, :completed})
    end
  end

  test "completed and failed are terminal: nothing transitions out" do
    for state <- [:completed, :failed] do
      assert GoalLifecycle.terminal?(state)

      for event <- [
            :dispatch_started,
            :run_terminal,
            {:run_terminal, :completed},
            :recheck_due,
            :handoff_requested,
            {:admission_decision, :admit},
            {:command_outcome, :released}
          ] do
        assert {:error, {:invalid_transition, ^state, ^event}} =
                 GoalLifecycle.transition(state, event),
               "expected #{inspect(event)} to be rejected from #{state}"
      end
    end
  end

  test "needs_user waits: repeated needs_user stays, respond outcomes re-evaluate" do
    assert GoalLifecycle.transition(:needs_user, {:command_outcome, :needs_user}) ==
             {:ok, :needs_user}

    assert GoalLifecycle.transition(:needs_user, {:command_outcome, :abandoned}) ==
             {:ok, :evaluating}

    assert GoalLifecycle.transition(:needs_user, {:command_outcome, :released}) ==
             {:ok, :evaluating}

    assert GoalLifecycle.transition(:needs_user, {:command_outcome, :rejected}) ==
             {:ok, :evaluating}
  end

  test "needs_user still admits re-evaluation and handoff" do
    assert GoalLifecycle.transition(:needs_user, {:admission_decision, :admit}) ==
             {:ok, :queued}

    assert GoalLifecycle.transition(:needs_user, {:admission_decision, :defer_until}) ==
             {:ok, :sleeping}

    assert GoalLifecycle.transition(:needs_user, {:admission_decision, :require_confirmation}) ==
             {:ok, :needs_user}

    assert GoalLifecycle.transition(:needs_user, {:admission_decision, :reject}) ==
             {:ok, :handing_off}

    assert GoalLifecycle.transition(:needs_user, :handoff_requested) == {:ok, :handing_off}
  end

  test "a full admit -> claim -> work -> completed walk keeps the outcome class" do
    assert {:ok, :queued} = GoalLifecycle.transition(:evaluating, {:admission_decision, :admit})
    assert {:ok, :dispatching} = GoalLifecycle.transition(:queued, {:command_outcome, :claimed})
    assert {:ok, :working} = GoalLifecycle.transition(:dispatching, :dispatch_started)
    assert {:ok, :checkpointing} = GoalLifecycle.transition(:working, :checkpoint_started)
    assert {:ok, :working} = GoalLifecycle.transition(:checkpointing, :checkpoint_done)
    assert {:ok, :completed} = GoalLifecycle.transition(:working, {:run_terminal, :completed})
    assert GoalLifecycle.terminal?(:completed)
  end
end
