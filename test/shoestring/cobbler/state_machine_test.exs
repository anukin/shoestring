defmodule Shoestring.Cobbler.StateMachineTest do
  use ExUnit.Case, async: true

  alias Shoestring.Cobbler.StateMachine

  describe "states, terminal, and recoverable" do
    test "defines expected lifecycle states" do
      assert :pending in StateMachine.states()
      assert :active in StateMachine.states()
      assert :needs_user in StateMachine.states()
      assert :completed in StateMachine.states()
      assert :failed in StateMachine.states()
      assert :cancelled in StateMachine.states()
    end

    test "distinguishes recoverable needs_user from terminal states" do
      assert StateMachine.recoverable?(:needs_user)
      assert StateMachine.recoverable?("needs_user")
      refute StateMachine.recoverable?(:completed)
      refute StateMachine.recoverable?(:failed)
      refute StateMachine.recoverable?(:cancelled)
      refute StateMachine.recoverable?(:active)
      refute StateMachine.recoverable?(:pending)

      refute StateMachine.terminal?(:needs_user)
      refute StateMachine.terminal?("needs_user")
      assert StateMachine.terminal?(:completed)
      assert StateMachine.terminal?("completed")
      assert StateMachine.terminal?(:failed)
      assert StateMachine.terminal?("failed")
      assert StateMachine.terminal?(:cancelled)
      assert StateMachine.terminal?("cancelled")
    end

    test "identifies active state" do
      assert StateMachine.active?(:active)
      assert StateMachine.active?("active")
      refute StateMachine.active?(:pending)
      refute StateMachine.active?(:needs_user)
      refute StateMachine.active?(:completed)
    end
  end

  describe "legal transitions" do
    test "from :pending" do
      assert {:ok, :active} = StateMachine.transition(:pending, :claim)
      assert {:ok, :needs_user} = StateMachine.transition(:pending, :needs_user)
      assert {:ok, :failed} = StateMachine.transition(:pending, :fail)
      assert {:ok, :cancelled} = StateMachine.transition(:pending, :cancel)

      # String variants
      assert {:ok, :active} = StateMachine.transition("pending", "claim")
      assert StateMachine.legal_transition?("pending", "claim")
    end

    test "from :active" do
      assert {:ok, :needs_user} = StateMachine.transition(:active, :needs_user)
      assert {:ok, :completed} = StateMachine.transition(:active, :complete)
      assert {:ok, :failed} = StateMachine.transition(:active, :fail)
      assert {:ok, :cancelled} = StateMachine.transition(:active, :cancel)

      assert StateMachine.legal_transition?(:active, :complete)
    end

    test "from :needs_user (recovery and termination)" do
      # Recovery back to active
      assert {:ok, :active} = StateMachine.transition(:needs_user, :resume)
      assert {:ok, :failed} = StateMachine.transition(:needs_user, :fail)
      assert {:ok, :cancelled} = StateMachine.transition(:needs_user, :cancel)

      assert StateMachine.legal_transition?(:needs_user, :resume)
    end
  end

  describe "illegal transitions and terminal protection" do
    test "terminal states reject all transitions" do
      terminal_states = [:completed, :failed, :cancelled]
      events = [:claim, :needs_user, :resume, :complete, :fail, :cancel]

      for state <- terminal_states, event <- events do
        assert {:error, {:illegal_transition, ^state, ^event}} =
                 StateMachine.transition(state, event)

        refute StateMachine.legal_transition?(state, event)
      end
    end

    test "invalid transitions from active or pending" do
      # Cannot resume if not in needs_user
      assert {:error, {:illegal_transition, :pending, :resume}} =
               StateMachine.transition(:pending, :resume)

      assert {:error, {:illegal_transition, :active, :resume}} =
               StateMachine.transition(:active, :resume)

      # Cannot claim if already active
      assert {:error, {:illegal_transition, :active, :claim}} =
               StateMachine.transition(:active, :claim)
    end

    test "unrecognized state or event" do
      assert {:error, {:illegal_transition, "bogus_state", :claim}} =
               StateMachine.transition("bogus_state", :claim)

      assert {:error, {:illegal_transition, :pending, "unsupported_event"}} =
               StateMachine.transition(:pending, "unsupported_event")
    end
  end
end
