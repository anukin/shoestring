defmodule Shoestring.Cobbler.PlanRunLineage do
  @moduledoc "Reconstruct plan attempts and their checkpoint continuations from canonical events."
  import Ecto.Query
  alias Shoestring.Cobbler.{ExecutionProfile, PlanBinding}
  alias Shoestring.Trajectory.TrajectoryEvent

  @stops ["run.failed", "run.interrupted", "run.cancelled", "run.suspended", "run.completed"]
  @types [
           "run.requested",
           "checkpoint.created",
           "dispatch.requested",
           "cobbler.plan.task.dispatched"
         ] ++ @stops
  def event_types, do: @types

  # Check before creating an intent and again at delivery. A checkpoint is
  # evidence of a boundary, never permission to duplicate a still-owned attempt.
  def authorize(repo, run) do
    binding = (run.extensions || %{})[PlanBinding.key()]
    continuation = run.continuation || %{}
    checkpoint_id = Map.get(continuation, "checkpoint_id", Map.get(continuation, :checkpoint_id))

    if is_map(binding) and is_binary(checkpoint_id) do
      events = events(repo, run.goal_id)

      checkpoint =
        Enum.find(
          events,
          &(&1.type == "checkpoint.created" and &1.payload["checkpoint_id"] == checkpoint_id)
        )

      parent_id = checkpoint && checkpoint.payload["run_id"]

      parent =
        Enum.find(events, &(&1.type == "run.requested" and &1.payload["run_id"] == parent_id))

      child = %{
        task_id: run.task_id,
        payload: %{
          "workspace_ref" => run.workspace_ref,
          "provider_id" => run.provider_id,
          "extensions" => run.extensions
        }
      }

      stop =
        events
        |> Enum.filter(&(&1.type in @stops and &1.payload["run_id"] == parent_id))
        |> List.last()

      with true <- same_attempt?(parent, child) || {:error, :plan_continuation_binding_mismatch},
           true <-
             (not is_nil(stop) and stop.type != "run.completed") ||
               {:error, :plan_continuation_parent_not_stopped},
           {:ok, chains} <- rebuild(events),
           {_root, ids} <- Enum.find(chains, fn {_root, ids} -> parent_id in ids end),
           true <- List.last(ids) in [parent_id, run.id] || {:error, :ambiguous_plan_continuation},
           false <- resolved?(events, ids, run.id) do
        :ok
      else
        {:error, _} = error -> error
        true -> {:error, :plan_attempt_already_resolved}
        _ -> {:error, :plan_continuation_parent_unknown}
      end
    else
      :ok
    end
  end

  defp resolved?(events, ids, own_id) do
    Enum.any?(events, fn event ->
      event.type in ["cobbler.plan.task.accepted", "cobbler.plan.task.gate_failed"] and
        event.payload["run_id"] in ids and event.payload["run_id"] != own_id
    end)
  end

  def load(repo, goal_id) do
    events(repo, goal_id) |> rebuild()
  end

  defp events(repo, goal_id) do
    types = @types ++ ["cobbler.plan.task.accepted", "cobbler.plan.task.gate_failed"]

    repo.all(
      from e in TrajectoryEvent,
        where: e.goal_id == ^goal_id and e.type in ^types,
        order_by: [asc: e.sequence]
    )
  end

  def rebuild(events) do
    requests = events |> Enum.filter(&(&1.type == "run.requested"))
    by_id = Map.new(requests, &{&1.payload["run_id"], &1})
    checkpoints = events |> Enum.filter(&(&1.type == "checkpoint.created"))
    parents = Map.new(checkpoints, &{&1.payload["checkpoint_id"], &1.payload["run_id"]})
    stops = events |> Enum.filter(&(&1.type in @stops)) |> Map.new(&{&1.payload["run_id"], &1})

    delivered =
      events
      |> Enum.filter(&(&1.type == "dispatch.requested"))
      |> MapSet.new(& &1.payload["run_id"])

    roots =
      events
      |> Enum.filter(&(&1.type == "cobbler.plan.task.dispatched"))
      |> Map.new(&{&1.payload["run_id"], [&1.payload["run_id"]]})

    Enum.reduce_while(requests, {:ok, roots}, fn event, {:ok, chains} ->
      id = event.payload["run_id"]
      checkpoint = get_in(event.payload, ["continuation", "checkpoint_id"])
      parent = parents[checkpoint]

      root =
        Enum.find_value(chains, fn {root, ids} -> if parent in ids, do: root end)

      cond do
        is_nil(root) or not MapSet.member?(delivered, id) ->
          {:cont, {:ok, chains}}

        not same_attempt?(by_id[parent], event) ->
          {:halt, {:error, :plan_continuation_binding_mismatch}}

        Enum.any?(events, fn resolution ->
          resolution.type in ["cobbler.plan.task.accepted", "cobbler.plan.task.gate_failed"] and
            resolution.payload["run_id"] in chains[root] and resolution.sequence < event.sequence
        end) ->
          {:halt, {:error, :plan_attempt_already_resolved}}

        not stopped_before?(stops[parent], event) ->
          {:halt, {:error, :plan_continuation_parent_not_stopped}}

        List.last(chains[root]) != parent ->
          {:halt, {:error, :ambiguous_plan_continuation}}

        true ->
          {:cont, {:ok, Map.update!(chains, root, &(&1 ++ [id]))}}
      end
    end)
  end

  defp stopped_before?(nil, _), do: false
  defp stopped_before?(%{type: "run.completed"}, _), do: false
  defp stopped_before?(stop, request), do: stop.sequence < request.sequence

  defp same_attempt?(nil, _), do: false

  defp same_attempt?(parent, child) do
    left = parent.payload
    right = child.payload
    binding = get_in(left, ["extensions", PlanBinding.key()])

    is_map(binding) and parent.task_id == child.task_id and
      left["workspace_ref"] == right["workspace_ref"] and
      binding == get_in(right, ["extensions", PlanBinding.key()]) and
      get_in(left, ["extensions", ExecutionProfile.key()]) ==
        get_in(right, ["extensions", ExecutionProfile.key()]) and
      left["provider_id"] == right["provider_id"]
  end
end
