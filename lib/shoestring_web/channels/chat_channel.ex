defmodule ShoestringWeb.ChatChannel do
  @moduledoc """
  `conversation:SESSION`: one conversation for its chat client
  (`docs/chat-channel.md`).

  Joining starts the conversation's engine if it is not running, subscribes
  to its events, then pushes the stored events after the client's `after`
  in `events` batches; live events follow, each sequence at most once per
  join. A `state` snapshot (engine, grant, dispatches, capacity) is pushed
  when it changes, at most once a second. The client sends `say`,
  `cancel_turn` and `cancel_dispatch`.

  A client that stops reading never blocks the service: before each push the
  channel checks its connection's outgoing queue and, past 1,000 messages,
  pushes `detached` and closes. The client resumes with
  `after`.
  """
  use Phoenix.Channel

  require Logger

  alias Shoestring.{Conversations, Dispatches, Grants, Trajectory}
  alias Shoestring.CLI.Commands.{Capacity, Grant}
  alias ShoestringWeb.ChatDispatches
  alias Shoestring.CLI.WorkLoop
  alias Shoestring.Conversations.{Conversation, Engine}

  @state_ms 1_000
  @max_queue 1_000
  @batch 100
  @max_reason 500

  @impl true
  def join("conversation:" <> session, params, %{assigns: %{session_id: session}} = socket) do
    with {:ok, after_sequence} <- after_sequence(params),
         %Conversation{} = conversation <- Conversations.get(session),
         {:ok, _engine} <- engine(conversation) do
      :ok = Phoenix.PubSub.subscribe(Shoestring.PubSub, Trajectory.topic(conversation.id))
      send(self(), :backlog)

      {:ok, %{"session_id" => session},
       assign(socket,
         conversation: conversation,
         last: after_sequence,
         ready: false,
         snapshot: nil,
         dispatch_cache: %{},
         watched: nil
       )}
    else
      nil -> {:error, %{reason: "no_conversation"}}
      {:error, :invalid_after} -> {:error, %{reason: "invalid_after"}}
      {:error, _reason} -> {:error, %{reason: "engine_unavailable"}}
    end
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "unauthorized"}}

  defp after_sequence(params) do
    case Map.get(params, "after", 0) do
      n when is_integer(n) and n >= 0 -> {:ok, n}
      _ -> {:error, :invalid_after}
    end
  end

  defp engine(conversation) do
    case Conversations.engine(conversation) do
      nil -> Conversations.start(conversation, engine_opts())
      pid -> {:ok, pid}
    end
  end

  defp engine_opts, do: Application.get_env(:shoestring, :conversation_engine_opts, [])

  # -- Pushes ------------------------------------------------------------------

  @impl true
  def handle_info(:backlog, socket) do
    {:ok, events} = Trajectory.replay(socket.assigns.conversation.id)

    events
    |> Enum.filter(&(&1.sequence > socket.assigns.last))
    |> Enum.chunk_every(@batch)
    |> Enum.reduce_while({:noreply, socket}, fn batch, {:noreply, socket} ->
      case deliver(socket, batch) do
        {:noreply, socket} -> {:cont, {:noreply, socket}}
        stop -> {:halt, stop}
      end
    end)
    |> case do
      {:noreply, socket} ->
        send(self(), :state)
        {:noreply, assign(socket, :ready, true)}

      stop ->
        stop
    end
  end

  # Committed before the backlog was read, so it is in the backlog.
  def handle_info({:trajectory_event_committed, _event}, %{assigns: %{ready: false}} = socket),
    do: {:noreply, socket}

  def handle_info({:trajectory_event_committed, event}, socket) do
    if event.sequence > socket.assigns.last,
      do: deliver(socket, [event]),
      else: {:noreply, socket}
  end

  def handle_info(:state, socket) do
    Process.send_after(self(), :state, @state_ms)

    {rows, cache} =
      ChatDispatches.rows(
        socket.assigns.conversation.session_id,
        socket.assigns.dispatch_cache,
        DateTime.utc_now()
      )

    socket = assign(socket, :dispatch_cache, cache)
    snapshot = snapshot(socket.assigns.conversation, rows)

    if snapshot == socket.assigns.snapshot do
      watch_tick(socket)
    else
      with {:noreply, socket} <- push_bounded(socket, "state", snapshot) do
        watch_tick(assign(socket, :snapshot, snapshot))
      end
    end
  end

  defp deliver(socket, events) do
    payload = %{"events" => Enum.map(events, &event/1)}

    with {:noreply, socket} <- push_bounded(socket, "events", payload) do
      {:noreply, assign(socket, :last, List.last(events).sequence)}
    end
  end

  defp push_bounded(socket, name, payload) do
    case Process.info(socket.transport_pid, :message_queue_len) do
      {:message_queue_len, waiting} when waiting > @max_queue ->
        push(socket, "detached", %{"reason" => "slow_consumer"})
        {:stop, :normal, socket}

      _ ->
        push(socket, name, payload)
        {:noreply, socket}
    end
  end

  defp event(event) do
    %{
      "id" => event.id,
      "sequence" => event.sequence,
      "type" => event.type,
      "actor" => event.actor,
      "occurred_at" => event.occurred_at,
      "payload" => event.payload
    }
  end

  defp snapshot(conversation, rows) do
    grant = Grants.active(conversation.session_id)

    %{
      "engine" => engine_status(conversation),
      "grant" => grant && Grant.show(grant),
      "dispatches" => rows,
      "capacity" => Capacity.report()
    }
  end

  defp engine_status(conversation) do
    status = Engine.status(Engine.via(conversation.id))

    %{
      "state" => Atom.to_string(status.state),
      "turn_id" => status.turn_id,
      "pending_messages" => status.pending_messages,
      "pending_inbox" => status.pending_inbox,
      "hold" => status.hold
    }
  catch
    :exit, _ -> %{"state" => "stopped"}
  end

  # -- From the client ---------------------------------------------------------

  @impl true
  def handle_in("say", %{"message_id" => id, "text" => text}, socket)
      when is_binary(id) and is_binary(text) do
    to_engine(socket, fn engine -> Engine.say(engine, id, text) end)
  end

  def handle_in("cancel_turn", _payload, socket),
    do: to_engine(socket, &Engine.cancel_turn/1)

  def handle_in("cancel_dispatch", %{"dispatch_id" => id, "reason" => reason}, socket)
      when is_binary(id) and is_binary(reason) do
    session = socket.assigns.conversation.session_id

    result =
      cond do
        String.trim(reason) == "" or String.length(reason) > @max_reason ->
          {:error, :invalid_reason}

        true ->
          case Dispatches.get(id) do
            %{session_id: ^session} = dispatch ->
              Dispatches.cancel(dispatch, reason, requested_by: WorkLoop.default_human())

            _ ->
              {:error, :dispatch_not_found}
          end
      end

    case result do
      {:ok, _} -> {:reply, :ok, socket}
      {:error, reason} -> {:reply, {:error, %{"reason" => code(reason)}}, socket}
    end
  end

  def handle_in("watch_dispatch", %{"dispatch_id" => id}, socket) when is_binary(id) do
    session = socket.assigns.conversation.session_id

    case Dispatches.get(id) do
      %{session_id: ^session} = dispatch ->
        detail = ChatDispatches.detail(dispatch)
        steps = ChatDispatches.steps(dispatch, 0)
        watched = %{id: id, detail: detail, steps: steps, cursor: steps["last_sequence"] || 0}
        {:reply, {:ok, Map.put(detail, "steps", steps)}, assign(socket, :watched, watched)}

      _ ->
        {:reply, {:error, %{"reason" => "dispatch_not_found"}}, socket}
    end
  end

  def handle_in("unwatch_dispatch", _payload, socket),
    do: {:reply, :ok, assign(socket, :watched, nil)}

  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{"reason" => "invalid_request"}}, socket}

  defp watch_tick(%{assigns: %{watched: nil}} = socket), do: {:noreply, socket}

  defp watch_tick(socket) do
    watched = socket.assigns.watched

    case Dispatches.get(watched.id) do
      nil ->
        {:noreply, assign(socket, :watched, nil)}

      dispatch ->
        detail = ChatDispatches.detail(dispatch)
        steps = ChatDispatches.steps(dispatch, watched.cursor)

        if detail != watched.detail or (steps["entries"] != [] and steps != watched.steps) do
          with {:noreply, socket} <-
                 push_bounded(socket, "dispatch", Map.put(detail, "steps", steps)) do
            {:noreply,
             assign(socket, :watched, %{
               watched
               | detail: detail,
                 steps: steps,
                 cursor: steps["last_sequence"] || 0
             })}
          end
        else
          {:noreply, socket}
        end
    end
  end

  defp to_engine(socket, fun) do
    with {:ok, _pid} <- engine(socket.assigns.conversation) do
      case fun.(Engine.via(socket.assigns.conversation.id)) do
        :ok -> {:reply, :ok, socket}
        {:error, reason} -> {:reply, {:error, %{"reason" => code(reason)}}, socket}
      end
    else
      {:error, _reason} -> {:reply, {:error, %{"reason" => "engine_unavailable"}}, socket}
    end
  catch
    :exit, _ -> {:reply, {:error, %{"reason" => "engine_unavailable"}}, socket}
  end

  # Reasons the client can act on; anything else is logged, not echoed.
  @codes ~w(message_too_large pending_input_too_large context_limit_reached empty_message no_turn invalid_reason dispatch_not_found not_started non_human_identity)a

  defp code(reason) when reason in @codes, do: Atom.to_string(reason)
  defp code({:invalid_payload, _type, _version, _changeset}), do: "invalid_message"

  defp code(reason) do
    Logger.warning("chat request refused: #{inspect(reason, limit: 8)}")
    "refused"
  end
end
