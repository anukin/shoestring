defmodule Shoestring.Measurement.Brackets do
  @moduledoc """
  Fresh capacity readings taken immediately before and after a plan run while
  an operator-attested collection window is open.

  A reading must cost no quota, or it would contaminate the measurement it
  brackets. Codex has an explicit `account/rateLimits/read` that runs no model
  turn; Claude's only capacity signal arrives inside an inference session, so
  Claude runs are never bracketed and stay ineligible for calibration.

  Brackets are evidence only. They never block, delay beyond the read
  timeout, or change admission, dispatch, gates or the run's outcome. Any
  failure records nothing, and the dataset then excludes the row.
  """
  require Logger
  import Ecto.Query
  alias Shoestring.Cobbler.GoalLocalObservation
  alias Shoestring.Harness.{CapacitySnapshot, EventPayload}
  alias Shoestring.Measurement.Collection
  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.TrajectoryEvent

  @readable ~w(codex)

  def readable_providers, do: @readable

  @doc "Context naming one dispatch attempt of one plan task."
  def context(execution_id, plan_task_id, attempt),
    do: "#{execution_id}:#{plan_task_id}:#{attempt}"

  @doc "Record the before reading when a window is open for the provider now."
  def before(goal_id, provider, scope, context, opts \\ []) do
    guarded(fn ->
      now = Keyword.get(opts, :now, DateTime.utc_now())

      if provider in @readable and
           Collection.open_at(Collection.list(), provider, scope, now) do
        record(goal_id, "measurement-before", provider, context, opts)
      else
        :skipped
      end
    end)
  end

  @doc """
  Record the after reading for an attempt that has a before reading. Both
  readings are linked to the run through their attempt context, which the
  attempt's `cobbler.plan.task.dispatched` event maps to its run id.
  """
  def after_run(goal_id, provider, context, opts \\ []) do
    guarded(fn ->
      if provider in @readable and bracketed?(goal_id, context),
        do: record(goal_id, "measurement-after", provider, context, opts),
        else: :skipped
    end)
  end

  defp record(goal_id, flow, provider, context, opts) do
    reader = Keyword.get(opts, :reader, reader())

    with {:ok, %CapacitySnapshot{} = observed} <- reader.(provider),
         {:ok, snapshot} <- GoalLocalObservation.localize(observed, flow, goal_id, context),
         snapshot = mark(snapshot, flow, context),
         {:ok, _event} <-
           Trajectory.append(goal_id, %{
             "type" => "capacity.snapshot_observed",
             "schema_version" => 2,
             "actor" => "measurement",
             "occurred_at" => snapshot.observed_at,
             # One reading per attempt and side: a retry keeps the first.
             "idempotency_key" => "#{flow}:#{context}",
             "payload" => EventPayload.capacity_snapshot(snapshot)
           }) do
      # Not projected here: nothing waits on it, and a goal projector failing
      # on an unrelated event must not make a durable reading look lost.
      :recorded
    else
      other ->
        Logger.warning("#{flow} reading not recorded: #{inspect(reason(other))}")
        :not_recorded
    end
  end

  defp mark(snapshot, flow, context) do
    extensions =
      (snapshot.extensions || %{})
      |> Map.put("measurement:bracket", String.replace_prefix(flow, "measurement-", ""))
      |> Map.put("measurement:context", context)

    %{snapshot | extensions: extensions}
  end

  defp bracketed?(goal_id, context) do
    key = "measurement-before:#{context}"

    Repo.exists?(
      from e in TrajectoryEvent, where: e.goal_id == ^goal_id and e.idempotency_key == ^key
    )
  end

  defp reader,
    do: Application.get_env(:shoestring, :measurement_capacity_reader, &__MODULE__.codex_read/1)

  @doc false
  def codex_read("codex") do
    monitor = Shoestring.Harness.Capacity.CodexMonitor

    if Process.whereis(monitor),
      do: monitor.read_capacity(monitor, 5_000),
      else: {:error, :capacity_monitor_unavailable}
  end

  def codex_read(_provider), do: {:error, :no_inference_free_observation}

  defp guarded(fun) do
    fun.()
  rescue
    error ->
      Logger.warning("measurement reading failed: #{inspect(error.__struct__)}")
      :not_recorded
  catch
    kind, _reason ->
      Logger.warning("measurement reading failed: #{kind}")
      :not_recorded
  end

  defp reason({:error, reason}) when is_atom(reason), do: reason
  defp reason({:error, {reason, _}}) when is_atom(reason), do: reason
  defp reason(_), do: :unexpected_result
end
