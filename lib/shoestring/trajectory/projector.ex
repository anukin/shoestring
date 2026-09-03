defmodule Shoestring.Trajectory.Projector do
  @moduledoc """
  Deterministic goal/task projection and durable sequence progress.

  Rebuild preserves goal and task rows because canonical events have foreign
  keys to them. It resets derived status and position state, then applies the
  canonical sequence from one; event rows are never deleted or updated.
  """

  import Ecto.Changeset, only: [change: 2]
  import Ecto.Query

  alias Shoestring.Repo

  alias Shoestring.Trajectory.{
    EventRegistry,
    Goal,
    ProjectorPosition,
    ProjectorTransition,
    TrajectoryEvent
  }

  alias Shoestring.Trajectory.Task, as: TrajectoryTask

  @projector "goal_task"
  @version 1

  @doc "The durable projector identity and implementation version."
  @spec name() :: String.t()
  def name, do: @projector

  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Projects events after the persisted position, optionally stopping after a bounded count."
  @spec project(Ecto.UUID.t(), keyword()) :: {:ok, ProjectorPosition.t()} | {:error, term()}
  def project(goal_id, opts \\ []) do
    with {:ok, normalized_goal_id} <- cast_goal_id(goal_id) do
      do_project(normalized_goal_id, opts, 0)
    end
  end

  @doc "Resets derived goal/task state and replays canonical events from sequence one."
  @spec rebuild(Ecto.UUID.t(), keyword()) :: {:ok, ProjectorPosition.t()} | {:error, term()}
  def rebuild(goal_id, opts \\ []) do
    with {:ok, normalized_goal_id} <- cast_goal_id(goal_id),
         {:ok, _reset} <- Repo.transaction(fn -> reset_derived_state(normalized_goal_id) end) do
      project(normalized_goal_id, opts)
    end
  end

  @doc "Purely replays a validated fixture into goal/task structs without database writes."
  @spec replay_events(Goal.t(), [TrajectoryEvent.t()]) ::
          {:ok, %{goal: Goal.t(), tasks: %{String.t() => TrajectoryTask.t()}}}
          | {:error, term()}
  def replay_events(%Goal{} = goal, events) when is_list(events) do
    initial = %{goal: goal, tasks: %{}, last_sequence: 0}

    result =
      Enum.reduce_while(events, {:ok, initial}, fn event, {:ok, state} ->
        expected_sequence = state.last_sequence + 1

        if event.sequence != expected_sequence do
          {:halt, {:error, {:event_order, event.sequence, expected_sequence}}}
        else
          case project_pure_event(state, event) do
            {:ok, next_state} ->
              {:cont, {:ok, Map.put(next_state, :last_sequence, event.sequence)}}

            {:error, error} ->
              {:halt, {:error, error}}
          end
        end
      end)

    case result do
      {:ok, %{goal: projected_goal, tasks: tasks}} -> {:ok, %{goal: projected_goal, tasks: tasks}}
      error -> error
    end
  end

  defp do_project(goal_id, opts, applied_count) do
    case apply_next(goal_id) do
      {:ok, :done, position} ->
        {:ok, position}

      {:ok, :applied, event, position} ->
        case publish_projection(goal_id, event, opts) do
          :ok ->
            if reached_limit?(opts, applied_count + 1) do
              {:ok, position}
            else
              do_project(goal_id, opts, applied_count + 1)
            end

          {:error, reason} ->
            {:error, {:publish_failed, reason, position}}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp apply_next(goal_id) do
    case Repo.transaction(fn -> apply_next_in_transaction(goal_id) end) do
      {:ok, {:done, position}} -> {:ok, :done, position}
      {:ok, {:applied, event, position}} -> {:ok, :applied, event, position}
      {:ok, {:failed, failure, _position}} -> {:error, failure}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_next_in_transaction(goal_id) do
    position = load_or_create_position(goal_id)

    cond do
      position.status == "failed" ->
        {:failed, failure_from_position(position), position}

      position.version != @version ->
        fail_projection(
          position,
          position.last_sequence + 1,
          {:projector_version_mismatch, @projector, position.version, @version}
        )

      true ->
        expected_sequence = position.last_sequence + 1

        case Repo.one(
               from event in TrajectoryEvent,
                 where: event.goal_id == ^goal_id and event.sequence == ^expected_sequence
             ) do
          nil ->
            if Repo.exists?(
                 from event in TrajectoryEvent,
                   where: event.goal_id == ^goal_id and event.sequence > ^expected_sequence
               ) do
              fail_projection(position, expected_sequence, {:sequence_gap, expected_sequence})
            else
              {:done, position}
            end

          event ->
            apply_event_in_transaction(position, event)
        end
    end
  end

  defp apply_event_in_transaction(position, event) do
    case project_event_from_storage(event) do
      {:ok, projected_event} ->
        goal = Repo.get!(Goal, event.goal_id)
        task = load_task_for_event(projected_event)

        case ProjectorTransition.apply(goal, task, projected_event) do
          {:ok, transition} ->
            persist_transition(goal, task, transition)
            next_position = advance_position(position, event.sequence)
            {:applied, event, next_position}

          {:error, error} ->
            fail_projection(position, event.sequence, error)
        end

      {:error, error} ->
        fail_projection(position, event.sequence, error)
    end
  end

  defp project_pure_event(state, event) do
    with {:ok, projected_event} <- project_event_from_storage(event),
         task_id <- ProjectorTransition.referenced_task_id(projected_event),
         task <- Map.get(state.tasks, task_id),
         {:ok, transition} <- ProjectorTransition.apply(state.goal, task, projected_event) do
      tasks =
        case transition.task_action do
          :none -> state.tasks
          _action -> Map.put(state.tasks, transition.task.id, transition.task)
        end

      {:ok, %{goal: transition.goal, tasks: tasks}}
    end
  end

  defp project_event_from_storage(event) do
    with {:ok, validated} <- EventRegistry.validate(event_attributes(event)),
         {:ok, payload} <-
           EventRegistry.upcast(event.type, event.schema_version, validated.payload,
             now: event.occurred_at
           ) do
      {:ok, %{event | payload: payload}}
    end
  end

  defp load_task_for_event(event) do
    case ProjectorTransition.referenced_task_id(event) do
      nil -> nil
      task_id -> Repo.get(TrajectoryTask, task_id)
    end
  end

  defp persist_transition(goal, task, transition) do
    if transition.goal != goal do
      goal
      |> Goal.changeset(%{
        "title" => transition.goal.title,
        "description" => transition.goal.description,
        "status" => transition.goal.status
      })
      |> Repo.update!()
    end

    case transition.task_action do
      :none -> :ok
      :upsert when is_nil(task) -> insert_task!(transition.task)
      :upsert -> update_task!(task, transition.task)
      :update -> update_task!(task, transition.task)
    end
  end

  defp insert_task!(task) do
    task
    |> TrajectoryTask.changeset(task_attributes(task))
    |> Repo.insert!()
  end

  defp update_task!(original, task) do
    original
    |> TrajectoryTask.changeset(task_attributes(task))
    |> Repo.update!()
  end

  defp task_attributes(task) do
    %{
      "title" => task.title,
      "description" => task.description,
      "status" => task.status,
      "position" => task.position
    }
  end

  defp load_or_create_position(goal_id) do
    Repo.get_by(ProjectorPosition, goal_id: goal_id, projector: @projector) ||
      %ProjectorPosition{
        id: Ecto.UUID.generate(),
        goal_id: goal_id,
        projector: @projector,
        version: @version,
        last_sequence: 0,
        status: "ok"
      }
      |> Repo.insert!()
  end

  defp advance_position(position, sequence) do
    position
    |> change(last_sequence: sequence, status: "ok", error_detail: nil)
    |> Repo.update!()
  end

  defp fail_projection(position, sequence, error) do
    position =
      position
      |> change(status: "failed", error_detail: encode_failure(error))
      |> Repo.update!()

    {:failed, {:projection_failed, sequence, error}, position}
  end

  defp failure_from_position(position) do
    {:projection_failed, position.last_sequence + 1, decode_failure(position.error_detail)}
  end

  defp encode_failure(error) do
    inspected = inspect(error, limit: :infinity)
    encoded = error |> :erlang.term_to_binary() |> Base.encode64()
    inspected <> "\n" <> encoded
  end

  defp decode_failure(nil), do: :projection_failed

  defp decode_failure(detail) do
    case detail |> String.split("\n", parts: 2) |> List.last() |> Base.decode64() do
      {:ok, encoded} -> :erlang.binary_to_term(encoded, [:safe])
      :error -> {:projection_failed_detail, detail}
    end
  end

  defp reset_derived_state(goal_id) do
    Repo.get_by!(Goal, id: goal_id)

    Repo.update_all(from(task in TrajectoryTask, where: task.goal_id == ^goal_id),
      set: [status: "pending", position: 0]
    )

    case Repo.get_by(ProjectorPosition, goal_id: goal_id, projector: @projector) do
      nil ->
        load_or_create_position(goal_id)

      position ->
        position
        |> change(version: @version, last_sequence: 0, status: "ok", error_detail: nil)
        |> Repo.update!()
    end
  end

  defp publish_projection(goal_id, event, opts) do
    publish_fun = Keyword.get(opts, :publish_fun, &default_publish/3)
    message = {:trajectory_projection_updated, goal_id, event.sequence}

    try do
      case publish_fun.(Shoestring.PubSub, projection_topic(goal_id), message) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    rescue
      error -> {:error, Exception.message(error)}
    end
  end

  defp default_publish(pubsub, topic, message),
    do: Phoenix.PubSub.broadcast(pubsub, topic, message)

  defp projection_topic(goal_id), do: "trajectory:projection:#{goal_id}"

  defp reached_limit?(opts, applied_count) do
    case Keyword.get(opts, :max_events, :infinity) do
      :infinity -> false
      max_events when is_integer(max_events) and max_events >= 0 -> applied_count >= max_events
      _invalid -> false
    end
  end

  defp cast_goal_id(goal_id) do
    case Ecto.UUID.cast(goal_id) do
      {:ok, normalized_goal_id} -> {:ok, normalized_goal_id}
      :error -> {:error, {:invalid_goal_id, goal_id}}
    end
  end

  defp event_attributes(event) do
    %{
      id: event.id,
      goal_id: event.goal_id,
      task_id: event.task_id,
      run_id: event.run_id,
      sequence: event.sequence,
      parent_event_id: event.parent_event_id,
      type: event.type,
      actor: event.actor,
      occurred_at: event.occurred_at,
      schema_version: event.schema_version,
      payload: event.payload,
      idempotency_key: event.idempotency_key
    }
  end
end
