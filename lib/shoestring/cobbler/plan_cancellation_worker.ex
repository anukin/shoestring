defmodule Shoestring.Cobbler.PlanCancellationWorker do
  @moduledoc "Service-owned explicit plan cancellation; stops only the requested targets."
  use Oban.Worker,
    queue: :plan_cancellation,
    max_attempts: 5,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"goal_id" => goal_id, "cancellation_id" => id}}) do
    opts = Application.get_env(:shoestring, :plan_cancellation_opts, [])

    case Shoestring.Cobbler.PlanCancellation.perform(goal_id, id, opts) do
      {:ok, _} -> :ok
      {:error, :cancellation_not_found} -> {:cancel, :cancellation_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(_), do: {:cancel, :invalid_cancellation_job}
end
