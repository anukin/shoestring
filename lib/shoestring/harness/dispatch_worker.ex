defmodule Shoestring.Harness.DispatchWorker do
  @moduledoc "Oban delivery worker that claims durable state before invoking a harness effect."

  use Oban.Worker,
    queue: :dispatch,
    max_attempts: 5,
    unique: [period: :infinity, states: :all, keys: [:dispatch_id]]

  alias Shoestring.Harness.Dispatches

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"dispatch_id" => dispatch_id}}) do
    case Dispatches.prepare_for_effect(dispatch_id) do
      {:ok, {:execute, dispatch, run}} ->
        perform_effect(dispatch, run)

      {:ok, {:skip, _reason}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def perform(_job), do: {:error, :invalid_dispatch_job}

  defp perform_effect(dispatch, run) do
    case dispatch_effect().perform(run, dispatch) do
      :ok -> complete_effect(dispatch.dispatch_id)
      {:ok, _result} -> complete_effect(dispatch.dispatch_id)
      {:error, reason} -> {:error, {:effect_failed, reason}}
      result -> {:error, {:invalid_effect_result, result}}
    end
  end

  defp complete_effect(dispatch_id) do
    case Dispatches.complete_effect(dispatch_id) do
      :ok -> :ok
      {:error, reason} -> {:error, {:effect_completion_not_recorded, reason}}
    end
  end

  defp dispatch_effect do
    Application.get_env(
      :shoestring,
      :dispatch_effect,
      Shoestring.Harness.Dispatch.UnconfiguredEffect
    )
  end
end
