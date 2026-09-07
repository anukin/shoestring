defmodule Shoestring.Cobbler.StateMachine do
  @moduledoc """
  Pure, deterministic state machine for Cobbler intent lifecycles.

  Lifecycle States:
  - `:pending` - Admitted, inert intent waiting to be claimed.
  - `:active` - Exclusively claimed and active execution intent.
  - `:needs_user` - Suspended awaiting human operator input (RECOVERABLE).
  - `:completed` - Terminal success.
  - `:failed` - Terminal unrecoverable failure.
  - `:cancelled` - Terminal explicit cancellation.

  Safety Properties:
  - `:needs_user` is strictly recoverable via `:resume`.
  - `:completed`, `:failed`, and `:cancelled` are terminal; no transition
    can ever escape or modify a terminal state.
  """

  @states [:pending, :active, :needs_user, :completed, :failed, :cancelled]
  @terminal [:completed, :failed, :cancelled]
  @recoverable [:needs_user]

  @type state :: :pending | :active | :needs_user | :completed | :failed | :cancelled
  @type event :: :claim | :needs_user | :resume | :complete | :fail | :cancel

  @doc "Returns all recognized lifecycle states."
  @spec states() :: [state()]
  def states, do: @states

  @doc "Returns true if the state is terminal."
  @spec terminal?(state() | String.t()) :: boolean()
  def terminal?(state) when is_binary(state), do: terminal?(String.to_existing_atom(state))
  def terminal?(state), do: state in @terminal

  @doc "Returns true if the state is recoverable."
  @spec recoverable?(state() | String.t()) :: boolean()
  def recoverable?(state) when is_binary(state), do: recoverable?(String.to_existing_atom(state))
  def recoverable?(state), do: state in @recoverable

  @doc "Returns true if the state is active."
  @spec active?(state() | String.t()) :: boolean()
  def active?(:active), do: true
  def active?("active"), do: true
  def active?(_), do: false

  @doc "Returns true if a transition is legal from the given state."
  @spec legal_transition?(state() | String.t(), event() | String.t()) :: boolean()
  def legal_transition?(from_state, event) do
    case transition(from_state, event) do
      {:ok, _target} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Computes the deterministic next state for a valid lifecycle transition.

  Returns `{:ok, target_state}` or `{:error, {:illegal_transition, from_state, event}}`.
  """
  @spec transition(state() | String.t(), event() | String.t()) ::
          {:ok, state()}
          | {:error, {:illegal_transition, state() | String.t(), event() | String.t()}}
  def transition(from_state, event) when is_binary(from_state) do
    case normalize_state(from_state) do
      {:ok, state} -> transition(state, normalize_event(event))
      :error -> {:error, {:illegal_transition, from_state, event}}
    end
  end

  def transition(from_state, event) when is_atom(from_state) do
    normalized_event = normalize_event(event)

    case target(from_state, normalized_event) do
      {:ok, next_state} -> {:ok, next_state}
      :error -> {:error, {:illegal_transition, from_state, event}}
    end
  end

  # Pending transitions
  defp target(:pending, :claim), do: {:ok, :active}
  defp target(:pending, :needs_user), do: {:ok, :needs_user}
  defp target(:pending, :fail), do: {:ok, :failed}
  defp target(:pending, :cancel), do: {:ok, :cancelled}

  # Active transitions
  defp target(:active, :needs_user), do: {:ok, :needs_user}
  defp target(:active, :complete), do: {:ok, :completed}
  defp target(:active, :fail), do: {:ok, :failed}
  defp target(:active, :cancel), do: {:ok, :cancelled}

  # Needs User transitions (RECOVERABLE)
  defp target(:needs_user, :resume), do: {:ok, :active}
  defp target(:needs_user, :fail), do: {:ok, :failed}
  defp target(:needs_user, :cancel), do: {:ok, :cancelled}

  # Terminal states reject all transitions
  defp target(:completed, _), do: :error
  defp target(:failed, _), do: :error
  defp target(:cancelled, _), do: :error

  defp target(_, _), do: :error

  defp normalize_state(str) when is_binary(str) do
    case str do
      "pending" -> {:ok, :pending}
      "active" -> {:ok, :active}
      "needs_user" -> {:ok, :needs_user}
      "completed" -> {:ok, :completed}
      "failed" -> {:ok, :failed}
      "cancelled" -> {:ok, :cancelled}
      _ -> :error
    end
  end

  defp normalize_event(event) when is_atom(event), do: event
  defp normalize_event("claim"), do: :claim
  defp normalize_event("needs_user"), do: :needs_user
  defp normalize_event("resume"), do: :resume
  defp normalize_event("complete"), do: :complete
  defp normalize_event("fail"), do: :fail
  defp normalize_event("cancel"), do: :cancel
  defp normalize_event(other), do: other
end
