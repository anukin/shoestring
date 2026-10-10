defmodule Shoestring.Cobbler.PlanExecutionWorker do
  @moduledoc "Drive one authorized sequential plan through ordinary durable dispatch workers."
  use Oban.Worker,
    queue: :plan_execution,
    max_attempts: 5,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Shoestring.Cobbler.{ExecutionAdmission, ExecutionControl, PlanExecutor}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"goal_id" => goal_id, "execution_id" => execution_id}}) do
    with {:ok, request} <- ExecutionControl.request(goal_id, execution_id),
         {:ok, result} <- PlanExecutor.resume(goal_id, options(request)) do
      case result.disposition do
        :completed -> :ok
        :blocked -> {:cancel, :plan_needs_user}
        _ -> {:snooze, 5}
      end
    else
      {:error, {:execution_admission_blocked, _}} ->
        {:snooze, 60}

      {:error, :execution_request_mismatch} ->
        {:cancel, :execution_request_mismatch}

      {:error, {:authority_mismatch, _}} ->
        {:cancel, :plan_authority_changed}

      {:error, {:global_gate_failed, _}} ->
        {:cancel, :plan_needs_user}

      {:error, reason} when reason in [:task_duration_exhausted, :total_duration_exhausted] ->
        {:cancel, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def perform(_), do: {:cancel, :invalid_execution_job}

  defp options(request) do
    runtime = Application.get_env(:shoestring, :plan_execution_opts, [])

    clock =
      Keyword.get(
        runtime,
        :clock,
        Application.get_env(:shoestring, :dispatch_clock, Shoestring.Harness.SystemClock)
      )

    admission = Keyword.get(runtime, :admission_fun, &ExecutionAdmission.admit/4)

    runtime
    |> Keyword.put_new(:clock, clock)
    |> Keyword.put_new(:now, Shoestring.Harness.Clock.now(clock))
    |> Keyword.merge(repository_path: request["repository_path"], admission_fun: admission)
  end
end
