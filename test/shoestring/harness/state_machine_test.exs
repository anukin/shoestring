defmodule Shoestring.Harness.StateMachineTest do
  use ExUnit.Case, async: true

  alias Shoestring.Harness.{LeaseStateMachine, RunStateMachine}

  @run_events [
    :request,
    :begin,
    :started,
    :pause,
    :suspend,
    :resume,
    :complete,
    :fail,
    :interrupt,
    :cancel,
    :cancelled
  ]
  @lease_events [
    :propose,
    :grant,
    :activate,
    :renewal_due,
    :renew,
    :continue,
    :expire,
    :revoke,
    :require_checkpoint
  ]

  @run_transitions %{
    {:requested, :request} => :requested,
    {:requested, :begin} => :starting,
    {:starting, :started} => :running,
    {:starting, :fail} => :failed,
    {:starting, :cancel} => :cancelling,
    {:running, :pause} => :pausing,
    {:running, :complete} => :completed,
    {:running, :fail} => :failed,
    {:running, :cancel} => :cancelling,
    {:pausing, :suspend} => :suspended,
    {:pausing, :fail} => :failed,
    {:pausing, :cancel} => :cancelling,
    {:suspended, :resume} => :starting,
    {:suspended, :begin} => :starting,
    {:suspended, :cancel} => :cancelling,
    {:cancelling, :cancelled} => :cancelled,
    {:starting, :interrupt} => :interrupted,
    {:running, :interrupt} => :interrupted,
    {:pausing, :interrupt} => :interrupted,
    {:suspended, :interrupt} => :interrupted,
    {:interrupted, :interrupt} => :interrupted,
    {:completed, :complete} => :completed,
    {:failed, :fail} => :failed,
    {:cancelled, :cancelled} => :cancelled
  }

  @lease_transitions %{
    {:proposed, :propose} => :proposed,
    {:proposed, :grant} => :granted,
    {:granted, :activate} => :active,
    {:active, :renewal_due} => :renewal_due,
    {:renewal_due, :renew} => :renewed,
    {:renewed, :continue} => :active,
    {:renewed, :activate} => :active,
    {:granted, :expire} => :expired,
    {:active, :expire} => :expired,
    {:renewal_due, :expire} => :expired,
    {:renewed, :expire} => :expired,
    {:granted, :revoke} => :revoked,
    {:active, :revoke} => :revoked,
    {:renewal_due, :revoke} => :revoked,
    {:renewed, :revoke} => :revoked,
    {:expired, :require_checkpoint} => :checkpoint_required,
    {:revoked, :require_checkpoint} => :checkpoint_required,
    {:checkpoint_required, :require_checkpoint} => :checkpoint_required
  }

  test "every legal run transition and terminal idempotency is explicit" do
    for {{state, event}, expected} <- @run_transitions do
      assert {:ok, %{state: ^expected, idempotent?: idempotent?}} =
               RunStateMachine.transition(state, event)

      assert idempotent? == (state == expected)
    end
  end

  test "every unspecified run state-event pair returns an invalid-transition diagnostic" do
    for state <- RunStateMachine.states(),
        event <- @run_events,
        not Map.has_key?(@run_transitions, {state, event}) do
      assert {:error, %{category: :invalid_transition, code: "run_transition_rejected"}} =
               RunStateMachine.transition(state, event)
    end
  end

  test "every legal lease transition, including safe-boundary expiration, is explicit" do
    for {{state, event}, expected} <- @lease_transitions do
      assert {:ok,
              %{
                state: ^expected,
                idempotent?: idempotent?,
                checkpoint_required?: checkpoint_required?
              }} =
               LeaseStateMachine.transition(state, event)

      assert idempotent? == (state == expected)
      assert checkpoint_required? == expected in [:expired, :revoked, :checkpoint_required]
    end
  end

  test "every unspecified lease state-event pair returns an invalid-transition diagnostic" do
    for state <- LeaseStateMachine.states(),
        event <- @lease_events,
        not Map.has_key?(@lease_transitions, {state, event}) do
      assert {:error, %{category: :invalid_transition, code: "lease_transition_rejected"}} =
               LeaseStateMachine.transition(state, event)
    end
  end
end
