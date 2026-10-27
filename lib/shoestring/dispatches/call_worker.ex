defmodule Shoestring.Dispatches.CallWorker do
  @moduledoc """
  Runs the call of one EXPLORE or REVIEW dispatch (`Shoestring.Dispatches.Calls`):
  a held call is checked again every half minute for a confirmation, and a
  deferred one sleeps until its provider's usage resets.
  """
  use Oban.Worker,
    queue: :coordinator_calls,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Shoestring.Dispatches.Calls

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"dispatch_id" => id}}) do
    case Calls.step(id) do
      {:snooze, seconds} -> {:snooze, seconds}
      :done -> :ok
      {:error, :call_not_found} -> {:cancel, :call_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(_job), do: {:cancel, :invalid_call_job}
end
