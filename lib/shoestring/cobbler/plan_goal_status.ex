defmodule Shoestring.Cobbler.PlanGoalStatus do
  @moduledoc """
  Keeps the generic goal row in step with canonical planned-goal completion.

  `cobbler.plan.execution.completed` is the only fact that completes a planned
  goal, and a goal-scope `cobbler.plan.cancellation.requested` is the only fact
  that cancels it; a later `cobbler.plan.execution.requested` reopens it. The
  row moves at the request, when the execution is fenced, not when the last
  child has stopped; status reports that progress separately. A child-scope
  cancellation never changes the row. The row is a
  derived cache of those facts: it is written in the same transaction as the
  source event, repaired from canonical history at startup, and never moves an
  `archived` or protected goal. A completion naming any execution other than
  the latest request is refused, so event order alone decides the status.
  """

  import Ecto.Query

  alias Shoestring.Repo
  alias Shoestring.Trajectory.{Goal, TrajectoryEvent}

  @requested "cobbler.plan.execution.requested"
  @completed "cobbler.plan.execution.completed"
  @cancelled "cobbler.plan.cancellation.requested"
  @types [@requested, @completed, @cancelled]
  @page 128

  @spec event_types() :: [String.t()]
  def event_types, do: @types

  @doc "Pure status transition shared by capture, repair and the goal/task projector."
  @spec status_after(String.t(), map()) :: String.t()
  def status_after(status, _event) when status in ["archived", "protected"], do: status
  def status_after(_status, %{type: @requested}), do: "active"
  def status_after(_status, %{type: @completed}), do: "completed"
  def status_after(_status, %{type: @cancelled, payload: %{"scope" => "goal"}}), do: "cancelled"
  def status_after(status, _event), do: status

  @doc "Called by the trajectory writer inside its append transaction."
  @spec capture(module(), TrajectoryEvent.t(), :inserted | :duplicate) :: :ok
  def capture(repo, %TrajectoryEvent{type: type} = event, mode) when type in @types do
    unless repo.in_transaction?(),
      do: raise(ArgumentError, "plan goal status needs a transaction")

    if mode == :inserted and type == @completed and not current_execution?(repo, event),
      do: repo.rollback(:stale_plan_execution_completion)

    {:ok, _outcome} = sync_in_transaction(repo, event.goal_id)
    :ok
  end

  def capture(_repo, _event, _mode), do: :ok

  @doc "Re-derives one goal row from its canonical plan execution history."
  @spec sync(Ecto.UUID.t(), keyword()) ::
          {:ok, :unchanged | :updated | :unplanned} | {:error, term()}
  def sync(goal_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    # Read then write. Under WAL a deferred transaction fails at once with
    # busy (no busy wait) if another writer commits between the two, so the
    # write lock is taken at BEGIN.
    case repo.transaction(
           fn ->
             case sync_in_transaction(repo, goal_id) do
               {:ok, outcome} -> outcome
               {:error, reason} -> repo.rollback(reason)
             end
           end,
           mode: :immediate
         ) do
      {:ok, outcome} -> {:ok, outcome}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Startup repair over every planned goal, in bounded pages. Repairs only the
  derived row; it never appends events or touches runs. Failures are counted
  with at most #{@page} goal references.
  """
  @spec reconcile(keyword()) :: {:ok, map()}
  def reconcile(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    reconcile_page(repo, nil, %{
      checked_count: 0,
      repaired_count: 0,
      failure_count: 0,
      failures: []
    })
  end

  defp reconcile_page(repo, after_id, acc) do
    query =
      from event in TrajectoryEvent,
        where: event.type == @requested,
        distinct: true,
        order_by: event.goal_id,
        limit: @page,
        select: event.goal_id

    query = if after_id, do: where(query, [event], event.goal_id > ^after_id), else: query
    ids = repo.all(query)

    acc =
      Enum.reduce(ids, acc, fn goal_id, acc ->
        case safe_sync(repo, goal_id) do
          {:ok, :updated} ->
            %{acc | checked_count: acc.checked_count + 1, repaired_count: acc.repaired_count + 1}

          {:ok, _} ->
            %{acc | checked_count: acc.checked_count + 1}

          {:error, reason} ->
            failure(acc, goal_id, reason)
        end
      end)

    if length(ids) == @page, do: reconcile_page(repo, List.last(ids), acc), else: {:ok, acc}
  end

  defp safe_sync(repo, goal_id) do
    sync(goal_id, repo: repo)
  rescue
    error -> {:error, {:exception, error.__struct__}}
  end

  defp failure(acc, goal_id, reason) do
    failures =
      if length(acc.failures) < @page,
        do: acc.failures ++ [%{goal_id: goal_id, reason: inspect(reason, limit: 8)}],
        else: acc.failures

    %{
      acc
      | checked_count: acc.checked_count + 1,
        failure_count: acc.failure_count + 1,
        failures: failures
    }
  end

  defp sync_in_transaction(repo, goal_id) do
    case repo.get(Goal, goal_id) do
      nil ->
        {:error, :goal_not_found}

      %Goal{} = goal ->
        events =
          repo.all(
            from event in TrajectoryEvent,
              where: event.goal_id == ^goal_id and event.type in ^@types,
              order_by: [asc: event.sequence],
              select: %{type: event.type, payload: event.payload}
          )

        cond do
          events == [] -> {:ok, :unplanned}
          Goal.observatory?(goal) -> {:ok, :unchanged}
          true -> write(repo, goal, Enum.reduce(events, goal.status, &status_after(&2, &1)))
        end
    end
  end

  defp write(_repo, %Goal{status: status}, status), do: {:ok, :unchanged}

  defp write(repo, goal, status) do
    case repo.update(Goal.changeset(goal, %{"status" => status})) do
      {:ok, _goal} -> {:ok, :updated}
      {:error, changeset} -> {:error, {:goal_status_invalid, changeset.errors}}
    end
  end

  defp current_execution?(repo, event) do
    latest =
      repo.one(
        from request in TrajectoryEvent,
          where:
            request.goal_id == ^event.goal_id and request.type == @requested and
              request.sequence < ^event.sequence,
          order_by: [desc: request.sequence],
          limit: 1,
          select: request.payload
      )

    is_map(latest) and latest["execution_id"] == event.payload["execution_id"]
  end
end
