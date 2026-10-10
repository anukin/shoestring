defmodule Shoestring.Cobbler.PlanSupersession do
  @moduledoc "An approved amendment may supersede a stopped checkpoint attempt, never a live run."
  import Ecto.Query
  alias Shoestring.Cobbler.PlanRunLineage
  alias Shoestring.Harness.RunRecord
  alias Shoestring.Trajectory.TrajectoryEvent

  @resolutions ~w(cobbler.plan.task.accepted cobbler.plan.task.gate_failed cobbler.plan.task.superseded)

  def boundary(repo, goal_id, status) do
    events =
      repo.all(
        from e in TrajectoryEvent, where: e.goal_id == ^goal_id, order_by: [asc: e.sequence]
      )

    with ids when is_list(ids) and ids != [] <- status[:active_run_ids],
         {:ok, chains} <- PlanRunLineage.rebuild(events),
         true <- MapSet.new(unresolved_ids(repo, goal_id, events, chains)) == MapSet.new(ids),
         true <- Enum.all?(ids, &(not live_elf?(&1))),
         run_id = List.last(ids),
         %RunRecord{dispatch_id: dispatch_id} <- repo.get(RunRecord, run_id),
         stop when not is_nil(stop) <-
           events
           |> Enum.filter(
             &(&1.payload["run_id"] == run_id and String.starts_with?(&1.type, "run."))
           )
           |> List.last(),
         true <- stopped?(stop),
         true <- stop.idempotency_key == "elf-terminal:#{dispatch_id}",
         checkpoint when not is_nil(checkpoint) <-
           events
           |> Enum.filter(&(&1.type == "checkpoint.created" and &1.payload["run_id"] == run_id))
           |> List.last(),
         dispatch when not is_nil(dispatch) <-
           Enum.find(
             events,
             &(&1.type == "cobbler.plan.task.dispatched" and &1.payload["run_id"] == hd(ids))
           ),
         true <- dispatch.payload["execution_id"] == status.execution.execution_id do
      {:ok,
       %{
         dispatch: dispatch.payload,
         run_id: run_id,
         checkpoint_id: checkpoint.payload["checkpoint_id"]
       }}
    else
      _ -> {:error, :active_plan_execution}
    end
  end

  def prepare(repo, goal_id, status, successor) do
    with true <-
           status[:planned?] and status.execution.revision_number != successor["revision_number"],
         {:ok, boundary} <- boundary(repo, goal_id, status) do
      payload =
        boundary.dispatch
        |> Map.take(~w(execution_id plan_task_id revision_number plan_digest attempt))
        |> Map.merge(%{
          "run_id" => boundary.run_id,
          "checkpoint_id" => boundary.checkpoint_id,
          "successor_execution_id" => successor["execution_id"],
          "successor_revision_number" => successor["revision_number"],
          "successor_plan_digest" => successor["plan_digest"]
        })

      {:ok,
       %{
         "type" => "cobbler.plan.task.superseded",
         "payload" => payload,
         "idempotency_key" =>
           "plan-task-superseded:#{payload["execution_id"]}:#{payload["plan_task_id"]}:#{payload["attempt"]}"
       }}
    else
      _ -> {:error, :active_plan_execution}
    end
  end

  defp unresolved_ids(repo, goal_id, events, chains) do
    resolved =
      events |> Enum.filter(&(&1.type in @resolutions)) |> MapSet.new(& &1.payload["run_id"])

    resolved =
      Enum.reduce(chains, resolved, fn {_root, ids}, acc ->
        if MapSet.member?(acc, List.last(ids)),
          do: Enum.reduce(ids, acc, &MapSet.put(&2, &1)),
          else: acc
      end)

    repo.all(from run in RunRecord, where: run.goal_id == ^goal_id)
    |> Enum.filter(
      &(is_map((&1.extensions || %{})["shoestring.plan:binding"]) and
          not MapSet.member?(resolved, &1.id))
    )
    |> Enum.map(& &1.id)
  end

  defp stopped?(%{type: "run.failed", payload: %{"error_category" => "quota_refused"}}), do: true

  defp stopped?(%{type: type}) when type in ~w(run.interrupted run.cancelled),
    do: true

  defp stopped?(_), do: false

  defp live_elf?(id) do
    if Process.whereis(Shoestring.Elves.Registry),
      do: not is_nil(Shoestring.Elves.whereis(id)),
      else: false
  end
end
