defmodule Shoestring.Trajectory.ProjectorTransition do
  @moduledoc "Pure deterministic goal/task transitions for the v1 trajectory events."

  alias Shoestring.Trajectory.{Goal, Task, TrajectoryEvent}

  @type result ::
          {:ok, %{goal: Goal.t(), task: Task.t() | nil, task_action: :none | :upsert | :update}}
          | {:error, {:invalid_transition, atom(), term()}}

  @doc "Applies one already envelope- and payload-validated event without persistence."
  @spec apply(Goal.t(), Task.t() | nil, TrajectoryEvent.t()) :: result()
  def apply(%Goal{} = goal, task, %TrajectoryEvent{goal_id: goal_id} = event)
      when goal.id == goal_id do
    case event.type do
      "goal.created" -> goal_created(goal, task, event)
      "task.created" -> task_created(goal, task, event)
      "decision.recorded" -> {:ok, %{goal: goal, task: task, task_action: :none}}
      "task.completed" -> task_completed(goal, task, event)
      type -> {:error, {:invalid_transition, :unsupported_event, type}}
    end
  end

  def apply(%Goal{}, _task, %TrajectoryEvent{goal_id: goal_id}),
    do: {:error, {:invalid_transition, :goal_mismatch, goal_id}}

  @doc "Returns the task id carried by a task event, checking no relationship fields."
  @spec referenced_task_id(TrajectoryEvent.t()) :: String.t() | nil
  def referenced_task_id(%TrajectoryEvent{type: type, task_id: task_id, payload: payload})
      when type in ["task.created", "task.completed"] do
    payload_task_id = Map.get(payload, "task_id")

    cond do
      is_nil(task_id) -> payload_task_id
      is_nil(payload_task_id) -> task_id
      task_id == payload_task_id -> task_id
      true -> nil
    end
  end

  def referenced_task_id(_event), do: nil

  defp goal_created(goal, task, event) do
    changes = %{
      "title" => Map.fetch!(event.payload, "title"),
      "description" => Map.get(event.payload, "description"),
      "status" => "active"
    }

    case Goal.changeset(goal, changes) do
      %{valid?: true} = changeset ->
        {:ok, %{goal: Ecto.Changeset.apply_changes(changeset), task: task, task_action: :none}}

      _changeset ->
        {:error, {:invalid_transition, :goal_created, event.sequence}}
    end
  end

  defp task_created(goal, task, event) do
    task_id = referenced_task_id(event)

    cond do
      is_nil(task_id) ->
        {:error, {:invalid_transition, :task_id_mismatch, event.sequence}}

      not is_nil(task) and task.goal_id != goal.id ->
        {:error, {:invalid_transition, :task_not_owned, task_id}}

      true ->
        task = task || %Task{id: task_id, goal_id: goal.id}

        changes = %{
          "title" => Map.fetch!(event.payload, "title"),
          "description" => Map.get(event.payload, "description")
        }

        case Task.changeset(task, changes) do
          %{valid?: true} = changeset ->
            {:ok,
             %{
               goal: goal,
               task: Ecto.Changeset.apply_changes(changeset),
               task_action: :upsert
             }}

          _changeset ->
            {:error, {:invalid_transition, :task_created, task_id}}
        end
    end
  end

  defp task_completed(_goal, nil, event),
    do: {:error, {:invalid_transition, :task_not_found, referenced_task_id(event)}}

  defp task_completed(goal, %Task{goal_id: goal_id}, _event) when goal_id != goal.id,
    do: {:error, {:invalid_transition, :task_not_owned, goal_id}}

  defp task_completed(goal, task, event) do
    task_id = referenced_task_id(event)

    cond do
      is_nil(task_id) or task.id != task_id ->
        {:error, {:invalid_transition, :task_id_mismatch, event.sequence}}

      task.status in ["pending", "in_progress", "completed"] ->
        changeset = Task.changeset(task, %{"status" => "completed"})
        {:ok, %{goal: goal, task: Ecto.Changeset.apply_changes(changeset), task_action: :update}}

      true ->
        {:error, {:invalid_transition, :task_status, task.status}}
    end
  end
end
