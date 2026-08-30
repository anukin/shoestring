defmodule ShoestringWeb.TrajectoryTimelineLive do
  use ShoestringWeb, :live_view

  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{Goal, ProjectorPosition, Redaction, TrajectoryEvent}

  @projector "goal_task"
  @payload_fields %{
    "goal.created" => ~w(title description artifact_id),
    "task.created" => ~w(task_id title description artifact_id),
    "decision.recorded" => ~w(decision rationale artifact_id),
    "task.completed" => ~w(task_id result artifact_id)
  }

  @impl true
  def mount(%{"goal_id" => raw_goal_id}, _session, socket) do
    socket = assign_new(socket, :current_scope, fn -> nil end)
    socket = subscribe_when_connected(socket, raw_goal_id)
    {:ok, load_timeline(socket, raw_goal_id)}
  end

  def mount(_params, _session, socket) do
    socket = assign_new(socket, :current_scope, fn -> nil end)
    {:ok, load_timeline(socket, nil)}
  end

  @impl true
  def handle_info({:trajectory_event_committed, %TrajectoryEvent{goal_id: goal_id}}, socket) do
    refresh_if_current_goal(socket, goal_id)
  end

  @impl true
  def handle_info({:trajectory_projection_updated, goal_id, _sequence}, socket) do
    refresh_if_current_goal(socket, goal_id)
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  defp refresh_if_current_goal(socket, goal_id) do
    if socket.assigns.goal_id == goal_id do
      {:noreply, load_timeline(socket, goal_id)}
    else
      {:noreply, socket}
    end
  end

  defp load_timeline(socket, raw_goal_id) do
    socket = assign(socket, :goal_id, raw_goal_id)

    case Ecto.UUID.cast(raw_goal_id) do
      {:ok, goal_id} -> load_goal(socket, goal_id, raw_goal_id)
      :error -> error_state(socket, nil, nil, :invalid_goal_id)
    end
  end

  defp load_goal(socket, goal_id, raw_goal_id) do
    case Repo.get(Goal, goal_id) do
      nil ->
        error_state(socket, nil, nil, {:goal_not_found, raw_goal_id})

      goal ->
        position = Repo.get_by(ProjectorPosition, goal_id: goal_id, projector: @projector)

        if authorized_goal?(goal, socket.assigns.current_scope) do
          load_replay(socket, goal, position)
        else
          error_state(socket, nil, position, {:unauthorized, goal_id})
        end
    end
  end

  defp load_replay(socket, goal, position) do
    with {:ok, events} <- Trajectory.replay(goal.id),
         :ok <- validate_event_order(events) do
      socket
      |> assign(:goal, goal)
      |> assign(:timeline_error, nil)
      |> assign(:projection, projection_state(position))
      |> stream(:events, events, reset: true, dom_id: &event_dom_id/1)
    else
      {:error, error} -> error_state(socket, goal, position, error)
    end
  end

  defp error_state(socket, goal, position, error) do
    socket
    |> assign(:goal, goal)
    |> assign(:timeline_error, error_text(error))
    |> assign(:projection, projection_state(position))
    |> stream(:events, [], reset: true, dom_id: &event_dom_id/1)
  end

  defp projection_state(nil), do: %{status: "not_projected", error_detail: nil}

  defp projection_state(%ProjectorPosition{status: status, error_detail: detail}) do
    error_detail =
      if status == "failed" do
        safe_error_detail(detail) || "Projection halted; rebuild required."
      end

    %{status: status || "unknown", error_detail: error_detail}
  end

  defp validate_event_order(events) do
    Enum.reduce_while(events, 1, fn event, expected_sequence ->
      if event.sequence == expected_sequence do
        {:cont, expected_sequence + 1}
      else
        {:halt, {:error, {:timeline_event_order, event.sequence, expected_sequence}}}
      end
    end)
    |> case do
      {:error, error} -> {:error, error}
      _next_sequence -> :ok
    end
  end

  defp subscribe_when_connected(socket, raw_goal_id) do
    if connected?(socket) do
      case Ecto.UUID.cast(raw_goal_id) do
        {:ok, goal_id} ->
          :ok = Phoenix.PubSub.subscribe(Shoestring.PubSub, Trajectory.topic(goal_id))
          :ok = Phoenix.PubSub.subscribe(Shoestring.PubSub, projection_topic(goal_id))
          socket

        :error ->
          socket
      end
    else
      socket
    end
  end

  @doc "Authorizes local mode or an explicit scope owner for a goal."
  @spec authorized_goal?(Goal.t(), nil | map() | term()) :: boolean()
  def authorized_goal?(%Goal{}, nil), do: true

  def authorized_goal?(%Goal{owner_id: goal_owner_id}, scope) when is_map(scope) do
    case scope_owner_id(scope) do
      owner_id when is_binary(owner_id) ->
        with {:ok, scope_owner_id} <- Ecto.UUID.cast(owner_id),
             {:ok, goal_owner_id} <- Ecto.UUID.cast(goal_owner_id) do
          scope_owner_id == goal_owner_id
        else
          _error -> false
        end

      _missing_owner ->
        false
    end
  end

  def authorized_goal?(_goal, _scope), do: false

  defp scope_owner_id(scope) do
    scope_user = Map.get(scope, :user) || Map.get(scope, "user")

    case scope_user do
      user when is_map(user) -> Map.get(user, :id) || Map.get(user, "id")
      _other -> Map.get(scope, :user_id) || Map.get(scope, "user_id")
    end
  end

  defp event_dom_id(%TrajectoryEvent{id: id}), do: "timeline-event-#{id}"

  defp projection_topic(goal_id), do: "trajectory:projection:#{goal_id}"

  defp event_time(%TrajectoryEvent{occurred_at: occurred_at}),
    do: DateTime.to_iso8601(occurred_at)

  defp payload_summary(%TrajectoryEvent{type: type, payload: payload}) when is_map(payload) do
    fields = Map.get(@payload_fields, type, [])

    payload
    |> Map.take(fields)
    |> Redaction.redact()
    |> Jason.encode!()
    |> String.slice(0, 240)
  rescue
    _error -> "{}"
  end

  defp payload_summary(_event), do: "{}"

  defp error_text(:invalid_goal_id), do: "Goal unavailable."
  defp error_text({:goal_not_found, _goal_id}), do: "Goal unavailable."
  defp error_text({:unauthorized, _goal_id}), do: "Goal unavailable."

  defp error_text({:timeline_event_order, _sequence, _expected}),
    do: "Timeline history is not contiguous."

  defp error_text({:event_order, _sequence, _expected}), do: "Timeline history is not contiguous."

  defp error_text({:unknown_event_type, _type}),
    do: "Timeline contains an unsupported event type."

  defp error_text({:unknown_event_version, _type, _version}),
    do: "Timeline contains an unsupported event version."

  defp error_text(_error), do: "Timeline could not be replayed."

  defp safe_error_detail(detail) when is_binary(detail) do
    detail
    |> Redaction.redact()
    |> String.slice(0, 240)
  end

  defp safe_error_detail(_detail), do: nil
end
