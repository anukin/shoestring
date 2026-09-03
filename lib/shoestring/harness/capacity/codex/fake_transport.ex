defmodule Shoestring.Harness.Capacity.Codex.FakeTransport do
  @moduledoc """
  In-memory fake transport for exhaustive offline testing of `CodexMonitor`.

  Allows simulating JSON-RPC requests/responses, asynchronous notifications,
  interleaving, malformed frames, oversized payloads, disconnects, and errors
  without real OS processes or network access.
  """

  @behaviour Shoestring.Harness.Capacity.Codex.Transport

  use GenServer

  @impl Shoestring.Harness.Capacity.Codex.Transport
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl Shoestring.Harness.Capacity.Codex.Transport
  def send_frame(pid, frame) when is_pid(pid) do
    GenServer.call(pid, {:send_frame, frame})
  end

  @impl Shoestring.Harness.Capacity.Codex.Transport
  def close(pid) when is_pid(pid) do
    GenServer.call(pid, :close)
  catch
    :exit, _ -> :ok
  end

  # --- Test Helpers ---

  @doc "Pushes an incoming frame (map or raw string) to the monitor owner."
  def push_frame(pid, frame) when is_pid(pid) do
    GenServer.call(pid, {:push_frame, frame})
  end

  @doc "Pushes a JSON-RPC notification to the monitor owner."
  def push_notification(pid, method, params) when is_pid(pid) and is_binary(method) do
    frame = %{"method" => method, "params" => params}
    push_frame(pid, frame)
  end

  @doc "Simulates transport disconnection / process exit."
  def simulate_disconnect(pid, reason \\ :normal) when is_pid(pid) do
    GenServer.call(pid, {:simulate_disconnect, reason})
  end

  @doc "Simulates a transport error (e.g. :oversized_frame)."
  def simulate_error(pid, reason) when is_pid(pid) do
    GenServer.call(pid, {:simulate_error, reason})
  end

  @doc "Retrieves all frames sent by the monitor through this transport."
  def get_sent_frames(pid) when is_pid(pid) do
    GenServer.call(pid, :get_sent_frames)
  end

  @doc "Retrieves the latest frame sent by the monitor."
  def get_last_sent_frame(pid) when is_pid(pid) do
    case get_sent_frames(pid) do
      [] -> nil
      frames -> List.last(frames)
    end
  end

  @doc "Sets or updates the owner process receiving transport messages."
  def set_owner(pid, new_owner) when is_pid(pid) and is_pid(new_owner) do
    GenServer.call(pid, {:set_owner, new_owner})
  end

  @doc "Configures or overrides the auto-responder function or map."
  def set_auto_respond(pid, auto_respond) when is_pid(pid) do
    GenServer.call(pid, {:set_auto_respond, auto_respond})
  end

  # --- GenServer Callbacks ---

  @impl GenServer
  def init(opts) do
    owner = Keyword.get(opts, :owner)
    auto_respond = Keyword.get(opts, :auto_respond)
    emit_connected? = Keyword.get(opts, :emit_connected, true)
    max_frame_size = Keyword.get(opts, :max_frame_size)

    if owner && emit_connected? do
      send(owner, {:codex_transport_connected, self()})
    end

    {:ok,
     %{
       owner: owner,
       auto_respond: auto_respond,
       sent_frames: [],
       max_frame_size: max_frame_size,
       emit_connected?: emit_connected?,
       closed: false
     }}
  end

  @impl GenServer
  def handle_call({:set_owner, new_owner}, _from, state) do
    if state.emit_connected? do
      send(new_owner, {:codex_transport_connected, self()})
    end

    {:reply, :ok, %{state | owner: new_owner}}
  end

  @impl GenServer
  def handle_call({:send_frame, _frame}, _from, %{closed: true} = state) do
    {:reply, {:error, :closed}, state}
  end

  def handle_call({:send_frame, frame}, _from, state) do
    parsed_frame =
      cond do
        is_map(frame) ->
          frame

        is_binary(frame) ->
          case Jason.decode(frame) do
            {:ok, decoded} -> decoded
            _ -> frame
          end

        true ->
          frame
      end

    updated_frames = state.sent_frames ++ [parsed_frame]
    new_state = %{state | sent_frames: updated_frames}

    # If auto-responder is configured, compute and dispatch responses
    dispatch_auto_response(parsed_frame, new_state)

    {:reply, :ok, new_state}
  end

  def handle_call({:push_frame, frame}, _from, state) do
    line =
      if is_map(frame) do
        Jason.encode!(frame)
      else
        to_string(frame)
      end

    if state.max_frame_size && byte_size(line) > state.max_frame_size do
      send(state.owner, {:codex_transport_error, self(), :oversized_frame})
    else
      send(state.owner, {:codex_transport_frame, self(), line})
    end

    {:reply, :ok, state}
  end

  def handle_call({:simulate_disconnect, reason}, _from, state) do
    send(state.owner, {:codex_transport_closed, self(), reason})
    {:reply, :ok, %{state | closed: true}}
  end

  def handle_call({:simulate_error, reason}, _from, state) do
    send(state.owner, {:codex_transport_error, self(), reason})
    {:reply, :ok, state}
  end

  def handle_call(:get_sent_frames, _from, state) do
    {:reply, state.sent_frames, state}
  end

  def handle_call({:set_auto_respond, auto_respond}, _from, state) do
    {:reply, :ok, %{state | auto_respond: auto_respond}}
  end

  def handle_call(:close, _from, state) do
    send(state.owner, {:codex_transport_closed, self(), :normal})
    {:stop, :normal, :ok, %{state | closed: true}}
  end

  # --- Auto Response Dispatch ---

  defp dispatch_auto_response(frame, state) when is_map(frame) do
    case state.auto_respond do
      nil ->
        :ok

      fun when is_function(fun, 1) ->
        res =
          try do
            fun.(frame)
          rescue
            FunctionClauseError -> :ignore
          end

        case res do
          :ignore ->
            :ok

          nil ->
            :ok

          responses when is_list(responses) ->
            Enum.each(responses, &deliver_auto_frame(&1, state))

          response when is_map(response) or is_binary(response) ->
            deliver_auto_frame(response, state)
        end

      map when is_map(map) ->
        method = Map.get(frame, "method")
        id = Map.get(frame, "id")

        case Map.get(map, method) do
          nil ->
            :ok

          fun when is_function(fun, 1) ->
            response = fun.(frame)
            if response, do: deliver_auto_frame(response, state)

          response_template when is_map(response_template) ->
            response =
              if id, do: Map.put(response_template, "id", id), else: response_template

            deliver_auto_frame(response, state)
        end
    end
  end

  defp dispatch_auto_response(_frame, _state), do: :ok

  defp deliver_auto_frame(frame, state) do
    line = if is_map(frame), do: Jason.encode!(frame), else: to_string(frame)
    send(state.owner, {:codex_transport_frame, self(), line})
  end
end
