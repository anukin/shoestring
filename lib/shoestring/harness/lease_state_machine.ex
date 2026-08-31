defmodule Shoestring.Harness.LeaseStateMachine do
  @moduledoc "Pure lease lifecycle with deterministic, safe-boundary checkpoint semantics."

  alias Shoestring.Harness.Error

  @states [
    :proposed,
    :granted,
    :active,
    :renewal_due,
    :renewed,
    :expired,
    :revoked,
    :checkpoint_required
  ]
  @terminal [:checkpoint_required]

  @type state ::
          :proposed
          | :granted
          | :active
          | :renewal_due
          | :renewed
          | :expired
          | :revoked
          | :checkpoint_required

  @type event ::
          :propose
          | :grant
          | :activate
          | :renewal_due
          | :renew
          | :continue
          | :expire
          | :revoke
          | :require_checkpoint

  @spec states() :: [state()]
  def states, do: @states

  @spec terminal?(state()) :: boolean()
  def terminal?(state), do: state in @terminal

  @doc "An expiration requires a later safe boundary event before work is paused."
  @spec transition(state(), event()) ::
          {:ok, %{state: state(), idempotent?: boolean(), checkpoint_required?: boolean()}}
          | {:error, Error.t()}
  def transition(state, event) when state in @states do
    case target(state, event) do
      {:ok, target, checkpoint_required?} ->
        {:ok,
         %{
           state: target,
           idempotent?: target == state,
           checkpoint_required?: checkpoint_required?
         }}

      :error ->
        {:error, invalid_transition(state, event)}
    end
  end

  def transition(state, event), do: {:error, invalid_transition(state, event)}

  defp target(:proposed, :propose), do: {:ok, :proposed, false}
  defp target(:proposed, :grant), do: {:ok, :granted, false}
  defp target(:granted, :activate), do: {:ok, :active, false}
  defp target(:active, :renewal_due), do: {:ok, :renewal_due, false}
  defp target(:renewal_due, :renew), do: {:ok, :renewed, false}
  defp target(:renewed, :continue), do: {:ok, :active, false}
  defp target(:renewed, :activate), do: {:ok, :active, false}

  defp target(state, :expire) when state in [:granted, :active, :renewal_due, :renewed],
    do: {:ok, :expired, true}

  defp target(state, :revoke) when state in [:granted, :active, :renewal_due, :renewed],
    do: {:ok, :revoked, true}

  defp target(state, :require_checkpoint) when state in [:expired, :revoked],
    do: {:ok, :checkpoint_required, true}

  defp target(:checkpoint_required, :require_checkpoint), do: {:ok, :checkpoint_required, true}
  defp target(_state, _event), do: :error

  defp invalid_transition(state, event) do
    Error.new(
      :invalid_transition,
      "lease_transition_rejected",
      "lease transition #{inspect(event)} is not legal from #{inspect(state)}",
      details: %{
        "shoestring.harness:event" => inspect(event),
        "shoestring.harness:state" => inspect(state)
      }
    )
  end
end
