defmodule Shoestring.Harness.DispatchWorker do
  @moduledoc "Oban delivery worker that claims durable state before invoking a harness effect."

  use Oban.Worker,
    queue: :dispatch,
    max_attempts: 5,
    unique: [period: :infinity, states: :incomplete, keys: [:dispatch_id]]

  alias Shoestring.Harness.Dispatches

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"dispatch_id" => dispatch_id}}) do
    case Dispatches.prepare_for_effect(dispatch_id, dispatch_opts()) do
      {:ok, {:execute, dispatch, run}} ->
        perform_effect(dispatch, run)

      {:ok, {:skip, :effect_outcome_unknown}} ->
        unknown_outcome(dispatch_id, :effect_already_started)

      {:ok, {:skip, :effect_unknown}} ->
        {:cancel, :effect_outcome_unknown}

      {:ok, {:skip, :effect_failed}} ->
        {:cancel, :effect_failed}

      {:ok, {:skip, :effect_deferred}} ->
        deferred_outcome(dispatch_id)

      {:ok, {:skip, _reason}} ->
        :ok

      {:error, _reason} ->
        {:error, :dispatch_prepare_failed}
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
    case invoke_complete_effect(dispatch_id) do
      :ok ->
        :ok

      {:error, _reason} ->
        case Dispatches.record_effect_outcome(dispatch_id, "effect_unknown", dispatch_opts()) do
          :ok -> {:cancel, :effect_completion_not_recorded}
          {:error, _outcome_reason} -> {:error, :effect_outcome_not_recorded}
        end
    end
  end

  defp failed_outcome(dispatch_id, _reason) do
    case Dispatches.record_effect_outcome(dispatch_id, "effect_failed", dispatch_opts()) do
      :ok -> {:cancel, :effect_failed}
      {:error, _outcome_reason} -> {:error, :effect_outcome_not_recorded}
    end
  end

  defp unknown_outcome(dispatch_id, _reason) do
    case Dispatches.record_effect_outcome(dispatch_id, "effect_unknown", dispatch_opts()) do
      :ok -> {:cancel, :effect_outcome_unknown}
      {:error, _outcome_reason} -> {:error, :effect_outcome_not_recorded}
    end
  end

  defp deferred_outcome(dispatch_id) do
    case Dispatches.record_effect_outcome(dispatch_id, "effect_deferred", dispatch_opts()) do
      :ok -> {:cancel, :effect_deferred}
      {:error, _outcome_reason} -> {:error, :effect_outcome_not_recorded}
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
    Application.get_env(:shoestring, :dispatch_complete_effect, &Dispatches.complete_effect/2)
  end

  defp invoke_complete_effect(dispatch_id) do
    case complete_effect_fun() do
      complete_effect when is_function(complete_effect, 2) ->
        complete_effect.(dispatch_id, dispatch_opts())

      complete_effect when is_function(complete_effect, 1) ->
        complete_effect.(dispatch_id)
    end
  end

  defp dispatch_opts do
    [clock: Application.get_env(:shoestring, :dispatch_clock, Shoestring.Harness.SystemClock)]
  end
end
