defmodule Shoestring.Dispatches.ChainWorker do
  @moduledoc """
  Follows one dispatch that waits for another (iteration 16 C1,
  `Shoestring.Dispatches.follow/2`): checked every half minute until the
  dispatch it follows completes, and it starts, or it is called off. Waiting
  is never a reason to give up: a dispatch that waits for a person waits as
  long as that one does.
  """
  use Oban.Worker,
    queue: :coordinator_chains,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Shoestring.Dispatches

  @recheck_seconds 30

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"dispatch_id" => id}}) do
    case Dispatches.get(id) do
      nil ->
        {:cancel, :dispatch_not_found}

      dispatch ->
        case Dispatches.follow(dispatch) do
          :waiting -> {:snooze, @recheck_seconds}
          # A start that failed is recorded on the dispatch, as for any other.
          _started_called_off_or_none -> :ok
        end
    end
  end

  def perform(_job), do: {:cancel, :invalid_chain_job}
end
