defmodule Shoestring.Harness.RunStateMachine do
  @moduledoc "Pure, explicit, idempotent run lifecycle transitions."

  alias Shoestring.Harness.Error

  @states [
    :requested,
    :starting,
    :running,
    :pausing,
    :suspended,
    :completed,
    :failed,
    :cancelling,
    :cancelled
  ]
  @terminal [:completed, :failed, :cancelled]

  @type state ::
          :requested
          | :starting
          | :running
          | :pausing
          | :suspended
          | :completed
          | :failed
          | :cancelling
          | :cancelled

  @type event ::
          :request
          | :begin
          | :started
          | :pause
          | :suspend
          | :resume
          | :complete
          | :fail
          | :cancel
          | :cancelled

  @spec states() :: [state()]
  def states, do: @states

  @spec terminal?(state()) :: boolean()
  def terminal?(state), do: state in @terminal

  @spec transition(state(), event()) ::
          {:ok, %{state: state(), idempotent?: boolean()}} | {:error, Error.t()}
  def transition(state, event) when state in @states do
    case target(state, event) do
      {:ok, target} -> {:ok, %{state: target, idempotent?: target == state}}
      :error -> {:error, invalid_transition(state, event)}
    end
  end

  def transition(state, event), do: {:error, invalid_transition(state, event)}

  defp target(:requested, :request), do: {:ok, :requested}
  defp target(:requested, :begin), do: {:ok, :starting}
  defp target(:starting, :started), do: {:ok, :running}
  defp target(:running, :pause), do: {:ok, :pausing}
  defp target(:pausing, :suspend), do: {:ok, :suspended}
  defp target(:suspended, :resume), do: {:ok, :starting}
  defp target(:suspended, :begin), do: {:ok, :starting}
  defp target(:running, :complete), do: {:ok, :completed}
  defp target(:running, :fail), do: {:ok, :failed}
  defp target(:starting, :fail), do: {:ok, :failed}
  defp target(:pausing, :fail), do: {:ok, :failed}
  defp target(:running, :cancel), do: {:ok, :cancelling}
  defp target(:starting, :cancel), do: {:ok, :cancelling}
  defp target(:pausing, :cancel), do: {:ok, :cancelling}
  defp target(:suspended, :cancel), do: {:ok, :cancelling}
  defp target(:cancelling, :cancelled), do: {:ok, :cancelled}
  defp target(state, :complete) when state == :completed, do: {:ok, :completed}
  defp target(state, :fail) when state == :failed, do: {:ok, :failed}
  defp target(state, :cancelled) when state == :cancelled, do: {:ok, :cancelled}
  defp target(_state, _event), do: :error

  defp invalid_transition(state, event) do
    Error.new(
      :invalid_transition,
      "run_transition_rejected",
      "run transition #{inspect(event)} is not legal from #{inspect(state)}",
      details: %{
        "shoestring.harness:event" => inspect(event),
        "shoestring.harness:state" => inspect(state)
      }
    )
  end
end
