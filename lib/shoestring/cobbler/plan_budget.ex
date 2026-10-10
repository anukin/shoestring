defmodule Shoestring.Cobbler.PlanBudget do
  @moduledoc "Lifetime duration accounting from canonical execution events; never interrupts a run."
  import Ecto.Query
  alias Shoestring.Cobbler.PlanRunLineage
  alias Shoestring.Trajectory.TrajectoryEvent

  @stops ~w(run.completed run.failed run.interrupted run.cancelled run.suspended)
  @gates ~w(cobbler.plan.task.accepted cobbler.plan.task.gate_failed cobbler.plan.execution.completed cobbler.plan.execution.gate_failed)

  def usage(repo, goal_id, now) do
    types = Enum.uniq(PlanRunLineage.event_types() ++ @gates ++ ~w(run.starting run.running))

    events =
      repo.all(
        from e in TrajectoryEvent,
          where: e.goal_id == ^goal_id and e.type in ^types,
          order_by: [asc: e.sequence]
      )

    with {:ok, chains} <- PlanRunLineage.rebuild(events) do
      runs = Enum.group_by(events, & &1.payload["run_id"])
      dispatched = Enum.filter(events, &(&1.type == "cobbler.plan.task.dispatched"))

      task_runs =
        Enum.reduce(dispatched, %{}, fn event, acc ->
          ids = Map.get(chains, event.payload["run_id"], [event.payload["run_id"]])
          duration = Enum.sum(Enum.map(ids, &run_duration(Map.get(runs, &1, []), now)))
          Map.update(acc, event.payload["plan_task_id"], duration, &(&1 + duration))
        end)

      gate_events = Enum.filter(events, &(&1.type in @gates))

      task_gates =
        gate_events
        |> Enum.filter(&is_binary(&1.payload["plan_task_id"]))
        |> Enum.reduce(%{}, fn e, acc ->
          Map.update(acc, e.payload["plan_task_id"], gate_duration(e), &(&1 + gate_duration(e)))
        end)

      run_ms = task_runs |> Map.values() |> Enum.sum()
      gate_ms = gate_events |> Enum.map(&gate_duration/1) |> Enum.sum()

      {:ok,
       %{
         total_run_duration_ms: run_ms,
         total_gate_duration_ms: gate_ms,
         total_duration_ms: run_ms + gate_ms,
         task_duration_ms: Map.merge(task_runs, task_gates, fn _, run, gate -> run + gate end)
       }}
    end
  end

  def remaining(usage, contract, task, extra_ms \\ 0) do
    goal =
      contract.content["budget"]["max_total_duration_seconds"] * 1000 - usage.total_duration_ms -
        extra_ms

    task_remaining =
      task["execution"]["max_duration_seconds"] * 1000 -
        Map.get(usage.task_duration_ms, task["id"], 0) - extra_ms

    cond do
      goal <= 0 -> {:error, :total_duration_exhausted}
      task_remaining <= 0 -> {:error, :task_duration_exhausted}
      true -> {:ok, min(goal, task_remaining)}
    end
  end

  def global_remaining(usage, contract),
    do:
      max(
        0,
        contract.content["budget"]["max_total_duration_seconds"] * 1000 - usage.total_duration_ms
      )

  def authorize_continuation(repo, run) do
    binding = run.extensions["shoestring.plan:binding"]

    with %{} = authority <- Shoestring.Cobbler.Plans.authority(run.goal_id, repo: repo),
         {:ok, contract} <- Shoestring.Cobbler.PlanContract.new(authority.revision.content),
         %{} = task <-
           Enum.find(contract.content["tasks"], &(&1["id"] == binding["plan_task_id"])),
         {:ok, usage} <- usage(repo, run.goal_id, DateTime.utc_now()),
         {:ok, _} <- remaining(usage, contract, task) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_plan_binding}
    end
  end

  defp run_duration(events, now) do
    case Enum.find(events, &(&1.type in ["run.starting", "run.running"])) do
      nil ->
        0

      start ->
        stop = Enum.find(events, &(&1.sequence > start.sequence and &1.type in @stops))

        max(
          0,
          DateTime.diff(
            if(stop, do: stop.occurred_at, else: now),
            start.occurred_at,
            :millisecond
          )
        )
    end
  end

  defp gate_duration(%{payload: %{"duration_ms" => ms}}) when is_integer(ms) and ms >= 0, do: ms

  defp gate_duration(event),
    do:
      get_in(event.payload, ["evidence", "gates"])
      |> List.wrap()
      |> Enum.reduce(0, fn gate, acc -> acc + max(0, gate["duration_ms"] || 0) end)
end
