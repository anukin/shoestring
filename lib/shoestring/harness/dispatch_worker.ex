defmodule Shoestring.Harness.DispatchWorker do
  @moduledoc "Oban delivery worker that claims durable state before invoking a harness effect."

  use Oban.Worker,
    queue: :dispatch,
    max_attempts: 5,
    unique: [period: :infinity, states: :incomplete, keys: [:dispatch_id]]

  alias Shoestring.Harness.Dispatches

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"dispatch_id" => dispatch_id}}) do
    case Dispatches.prepare_for_effect(dispatch_id) do
      {:ok, {:execute, dispatch, run}} ->
        perform_effect(dispatch, run)

      {:ok, {:skip, :effect_outcome_unknown}} ->
        unknown_outcome(dispatch_id, :effect_already_started)

      {:ok, {:skip, :effect_unknown}} ->
        {:error, {:effect_outcome_unknown, :operator_review_required}}

      {:ok, {:skip, :effect_failed}} ->
        {:error, {:effect_failed, :already_recorded}}

      {:ok, {:skip, _reason}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def perform(_job), do: {:error, :invalid_dispatch_job}

  defp perform_effect(dispatch, run) do
    try do
      case dispatch_effect().perform(run, dispatch) do
        :ok -> complete_effect(dispatch.dispatch_id)
        {:ok, _result} -> complete_effect(dispatch.dispatch_id)
        {:error, reason} -> failed_outcome(dispatch.dispatch_id, reason)
        _result -> unknown_outcome(dispatch.dispatch_id, :invalid_effect_result)
      end
    rescue
      _error -> unknown_outcome(dispatch.dispatch_id, :effect_raised)
    catch
      _kind, _reason -> unknown_outcome(dispatch.dispatch_id, :effect_raised)
    end
  end

  defp complete_effect(dispatch_id) do
    case complete_effect_fun().(dispatch_id) do
      :ok ->
        :ok

      {:error, reason} ->
        case Dispatches.record_effect_outcome(dispatch_id, "effect_unknown") do
          :ok -> {:error, {:effect_completion_not_recorded, reason}}
          {:error, outcome_reason} -> {:error, {:effect_outcome_not_recorded, outcome_reason}}
        end
    end
  end

  defp failed_outcome(dispatch_id, reason) do
    case Dispatches.record_effect_outcome(dispatch_id, "effect_failed") do
      :ok -> {:error, {:effect_failed, reason}}
      {:error, outcome_reason} -> {:error, {:effect_outcome_not_recorded, outcome_reason}}
    end
  end

  defp unknown_outcome(dispatch_id, reason) do
    case Dispatches.record_effect_outcome(dispatch_id, "effect_unknown") do
      :ok -> {:error, {:effect_outcome_unknown, reason}}
      {:error, outcome_reason} -> {:error, {:effect_outcome_not_recorded, outcome_reason}}
    end
  end

  defp dispatch_effect do
    Application.get_env(
      :shoestring,
      :dispatch_effect,
      Shoestring.Harness.Dispatch.UnconfiguredEffect
    )
  end

  defp complete_effect_fun do
    Application.get_env(:shoestring, :dispatch_complete_effect, &Dispatches.complete_effect/1)
  end
end
