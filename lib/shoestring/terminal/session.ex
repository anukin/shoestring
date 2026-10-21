defmodule Shoestring.Terminal.Session do
  @moduledoc "One temporary, supervised PTY session; raw bytes never become canonical events."
  use GenServer, restart: :temporary
  alias Shoestring.Terminal.{Events, Launch, Ownership, Protocol}
  alias Shoestring.Harness.{Error, HarnessEvent}

  @window 65_536
  @log_limit 1_048_576
  @pending_limit 128

  def start_link(opts) do
    request = Keyword.fetch!(opts, :request)

    with {:ok, run_id} <- Events.run_id(request) do
      GenServer.start_link(__MODULE__, Keyword.put(opts, :run_id, run_id), name: via(run_id))
    end
  end

  def via(run_id), do: {:via, Registry, {Shoestring.Terminal.Registry, run_id}}
  def lookup(run_id), do: GenServer.whereis(via(run_id))
  def ready(run_id), do: GenServer.call(via(run_id), :ready)
  def status(run_id), do: GenServer.call(via(run_id), :status)
  def events(run_id), do: GenServer.call(via(run_id), :events)
  def attach(run_id, browser), do: GenServer.call(via(run_id), {:attach, browser})
  def detach(run_id), do: GenServer.call(via(run_id), :detach)
  def action(run_id, browser, action), do: GenServer.call(via(run_id), {:action, browser, action})
  def ack(run_id, sequence), do: GenServer.call(via(run_id), {:ack, sequence})
  def agent_input(run_id, bytes), do: GenServer.call(via(run_id), {:agent_input, bytes})
  def boundary(run_id), do: GenServer.call(via(run_id), :boundary)
  def cancel(run_id), do: GenServer.call(via(run_id), :cancel)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    Process.flag(:message_queue_data, :off_heap)
    request = Keyword.fetch!(opts, :request)
    owner = Keyword.fetch!(opts, :owner)

    with {:ok, helper} <- Launch.helper(),
         {:ok, profile} <-
           Launch.profile(
             Keyword.fetch!(opts, :provider),
             request,
             Keyword.fetch!(opts, :workdir)
           ) do
      port =
        Port.open({:spawn_executable, helper}, [
          :binary,
          :exit_status,
          :use_stdio,
          :hide,
          {:args, []},
          {:env,
           Enum.map(System.get_env(), fn {key, _value} -> {String.to_charlist(key), false} end)},
          {:busy_limits_port, {32_768, 65_536}},
          {:busy_limits_msgq, {16, 32}}
        ])

      state = %{
        request: request,
        run_id: Keyword.fetch!(opts, :run_id),
        owner: owner,
        owner_monitor: Process.monitor(owner),
        port: port,
        profile: profile,
        phase: :hello,
        buffer: <<>>,
        process_group: nil,
        waiters: [],
        events: [],
        ordinal: 0,
        sequence: 0,
        ring: <<>>,
        gap?: false,
        ownership: %Ownership{},
        clients: %{},
        terminal: nil,
        log: <<>>,
        retain?: Application.get_env(:shoestring, :terminal_log_retention, :disabled) == :redacted
      }

      case command(state, %{"op" => "hello", "version" => Protocol.version()}) do
        :ok -> {:ok, state}
        {:error, reason} -> {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:ready, from, %{phase: phase} = state) when phase in [:hello, :spawning] do
    if length(state.waiters) < 8,
      do: {:noreply, %{state | waiters: [from | state.waiters]}},
      else: {:reply, {:error, :too_many_waiters}, state}
  end

  def handle_call(:ready, _from, %{terminal: nil} = state),
    do: {:reply, {:ok, state.process_group}, state}

  def handle_call(:ready, _from, state), do: {:reply, {:error, :terminal_session_ended}, state}
  def handle_call(:status, {client, _}, state), do: {:reply, public(state, client), state}
  def handle_call(:events, _from, state), do: {:reply, {:ok, state.events}, %{state | events: []}}

  def handle_call({:attach, browser}, {client, _}, state) do
    cond do
      not valid_browser?(browser) ->
        {:reply, {:error, :unauthorized}, state}

      map_size(state.clients) >= 8 and not Map.has_key?(state.clients, client) ->
        {:reply, {:error, :attachment_limit}, state}

      true ->
        state = detach_client(state, client)

        attachment = %{
          browser: browser,
          monitor: Process.monitor(client),
          pending: [{state.sequence, byte_size(state.ring)}],
          bytes: byte_size(state.ring),
          last: state.sequence
        }

        state = put_in(state.clients[client], attachment)

        snapshot =
          Map.merge(public(state, client), %{
            data: Base.encode64(state.ring),
            sequence: state.sequence,
            gap: state.gap?
          })

        {:reply, {:ok, snapshot}, state}
    end
  end

  def handle_call(:detach, {client, _}, state), do: {:reply, :ok, detach_client(state, client)}

  def handle_call({:ack, sequence}, {client, _}, state) do
    case state.clients[client] do
      %{last: last} = attachment
      when is_integer(sequence) and sequence >= 0 and sequence <= last ->
        pending = Enum.reject(attachment.pending, fn {n, _} -> n <= sequence end)
        bytes = Enum.reduce(pending, 0, fn {_, n}, acc -> acc + n end)

        {:reply, :ok,
         put_in(state.clients[client], %{attachment | pending: pending, bytes: bytes})}

      _ ->
        {:reply, {:error, :invalid_ack}, state}
    end
  end

  def handle_call({:action, browser, action}, {client, _}, state) do
    if state.terminal == nil and match?(%{browser: ^browser}, state.clients[client]) do
      handle_action(action, browser, client, state)
    else
      {:reply, {:error, :terminal_unavailable}, state}
    end
  end

  def handle_call({:agent_input, bytes}, {owner, _}, %{owner: owner, terminal: nil} = state) do
    with {:ok, ownership} <- Ownership.agent_input(state.ownership),
         :ok <- send_input(state, bytes) do
      {:reply, :ok, %{state | ownership: ownership}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:boundary, {owner, _}, %{owner: owner, terminal: nil} = state) do
    ownership = Ownership.boundary(state.ownership)
    reply_ownership(state, ownership)
  end

  def handle_call(:cancel, _from, state) do
    if state.terminal == nil do
      _ = command(state, session_command(state, "terminate", %{"grace_ms" => 0}))
      {:reply, {:ok, :cancelled}, finish(state, "cancelled")}
    else
      {:reply, {:ok, :cancelled}, state}
    end
  end

  def handle_call(_message, _from, state), do: {:reply, {:error, :unauthorized}, state}

  @impl true
  def handle_info({port, {:data, bytes}}, %{port: port, terminal: nil} = state) do
    if elem(Process.info(self(), :message_queue_len), 1) > 128 do
      {:noreply, finish(state, "output_overflow")}
    else
      case Protocol.feed(state.buffer, bytes) do
        {:ok, frames, buffer} ->
          state = Enum.reduce(frames, %{state | buffer: buffer}, &frame/2)
          {:noreply, state}

        {:error, _} ->
          {:noreply, finish(state, "protocol_error")}
      end
    end
  end

  def handle_info({port, {:exit_status, _}}, %{port: port, terminal: nil} = state),
    do: {:noreply, finish(state, "helper_failed")}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_monitor: ref} = state),
    do: {:stop, :normal, finish(state, "helper_failed")}

  def handle_info({:DOWN, _ref, :process, client, _reason}, state),
    do: {:noreply, detach_client(state, client)}

  def handle_info({:EXIT, port, _reason}, %{port: port, terminal: nil} = state),
    do: {:noreply, finish(state, "helper_failed")}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: close_port(state.port)

  defp frame(_frame, %{terminal: terminal} = state) when terminal != nil, do: state

  defp frame(
         %{"op" => "hello", "version" => 1, "helper_version" => "0.1.1", "max_frame" => 65_536},
         %{phase: :hello} = state
       ) do
    message =
      Map.merge(Map.new(state.profile, fn {key, value} -> {Atom.to_string(key), value} end), %{
        "op" => "spawn",
        "request_id" => state.request.dispatch_id,
        "session_id" => state.run_id,
        "rows" => 24,
        "cols" => 80
      })

    case command(state, message) do
      :ok -> %{state | phase: :spawning}
      _ -> finish(state, "protocol_error")
    end
  end

  defp frame(%{"op" => "hello"}, %{phase: :hello} = state),
    do: finish(state, "incompatible_helper")

  defp frame(
         %{
           "op" => "spawned",
           "session_id" => id,
           "request_id" => request_id,
           "pid" => pgid,
           "process_group" => pgid
         },
         %{phase: :spawning, run_id: id, request: %{dispatch_id: request_id}} = state
       )
       when is_integer(pgid) and pgid > 1 do
    case Events.append(
           state.request,
           "terminal.session.started",
           %{"protocol_version" => 1, "process_group" => pgid},
           "terminal-start:#{id}"
         ) do
      {:ok, _} ->
        Enum.each(state.waiters, &GenServer.reply(&1, {:ok, pgid}))
        state = %{state | phase: :running, process_group: pgid, waiters: []}
        add_event(state, :lifecycle, %{})

      _ ->
        finish(state, "protocol_error")
    end
  end

  defp frame(
         %{"op" => "output", "session_id" => id, "sequence" => sequence, "data" => data},
         %{phase: :running, run_id: id} = state
       )
       when is_integer(sequence) and sequence == state.sequence + 1 and is_binary(data) and
              byte_size(data) <= 5464 do
    case Base.decode64(data) do
      {:ok, bytes} when byte_size(bytes) <= 4096 -> output(%{state | sequence: sequence}, bytes)
      _ -> finish(state, "protocol_error")
    end
  end

  defp frame(
         %{
           "op" => "exited",
           "session_id" => id,
           "exit_code" => code,
           "signal" => signal,
           "sequence" => sequence
         },
         %{phase: :running, run_id: id, sequence: sequence} = state
       )
       when is_integer(code) and code >= 0 and (is_nil(signal) or is_binary(signal)) do
    reason = if code == 0 and is_nil(signal), do: "exited", else: "child_failed"
    finish(state, reason, %{"exit_code" => code, "signal" => signal})
  end

  defp frame(
         %{"op" => op, "session_id" => id},
         %{phase: :running, run_id: id} = state
       )
       when op in ["resized", "signalled", "heartbeat"], do: state

  defp frame(_message, state), do: finish(state, "protocol_error")

  defp output(state, bytes) do
    if state.retain? and byte_size(state.log) + byte_size(bytes) > @log_limit do
      finish(state, "output_overflow")
    else
      ring = state.ring <> bytes
      gap? = state.gap? or byte_size(ring) > @window

      ring =
        if byte_size(ring) > @window,
          do: binary_part(ring, byte_size(ring) - @window, @window),
          else: ring

      state = %{
        state
        | ring: ring,
          gap?: gap?,
          log: if(state.retain?, do: state.log <> bytes, else: <<>>)
      }

      Enum.reduce(Map.keys(state.clients), state, fn client, state ->
        attachment = state.clients[client]

        if attachment.bytes + byte_size(bytes) <= @window and
             length(attachment.pending) < @pending_limit do
          send(client, {:terminal_output, state.sequence, bytes})

          put_in(state.clients[client], %{
            attachment
            | bytes: attachment.bytes + byte_size(bytes),
              pending: attachment.pending ++ [{state.sequence, byte_size(bytes)}],
              last: state.sequence
          })
        else
          send(client, {:terminal_detached, :slow_consumer})
          detach_client(state, client)
        end
      end)
    end
  end

  defp handle_action(:takeover, browser, client, state) do
    case Ownership.request(state.ownership, browser, client) do
      {:ok, ownership} -> reply_ownership(state, ownership, "human:local")
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_action(:release, browser, client, state) do
    case Ownership.release(state.ownership, browser, client) do
      {:ok, ownership} -> reply_ownership(state, ownership, "human:local")
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_action({:input, bytes}, browser, client, state) do
    with :ok <- Ownership.human_input(state.ownership, browser, client),
         :ok <- send_input(state, bytes) do
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_action({:resize, rows, cols}, browser, client, state)
       when is_integer(rows) and rows in 1..500 and is_integer(cols) and cols in 1..500 do
    with :ok <- Ownership.human_input(state.ownership, browser, client) do
      {:reply,
       command(state, session_command(state, "resize", %{"rows" => rows, "cols" => cols})), state}
    else
      error -> {:reply, error, state}
    end
  end

  defp handle_action({:signal, "INT"}, browser, client, state) do
    with :ok <- Ownership.human_input(state.ownership, browser, client) do
      {:reply, command(state, session_command(state, "signal", %{"signal" => "INT"})), state}
    else
      error -> {:reply, error, state}
    end
  end

  defp handle_action(_action, _browser, _client, state),
    do: {:reply, {:error, :invalid_terminal_action}, state}

  defp reply_ownership(state, ownership, actor \\ "system") do
    case persist_ownership(state, ownership, actor) do
      {:ok, state} -> {:reply, {:ok, public(state)}, state}
      {:error, reason} -> {:reply, {:error, reason}, finish(state, "protocol_error")}
    end
  end

  defp persist_ownership(state, ownership, actor \\ "system")

  defp persist_ownership(state, ownership, _actor) when ownership == state.ownership,
    do: {:ok, state}

  defp persist_ownership(state, ownership, actor) do
    owner_ref =
      if ownership.browser,
        do: :crypto.hash(:sha256, ownership.browser) |> Base.encode16(case: :lower),
        else: "none"

    case Events.append(
           state.request,
           "terminal.ownership.changed",
           %{
             "state" => Ownership.public(ownership),
             "owner_ref" => owner_ref
           },
           nil,
           actor
         ) do
      {:ok, _} ->
        state = %{state | ownership: ownership}
        broadcast(state, {:terminal_status, public(state)})
        {:ok, state}

      _ ->
        {:error, :terminal_ownership_not_persisted}
    end
  end

  defp detach_client(state, client) do
    case Map.pop(state.clients, client) do
      {nil, _} ->
        state

      {attachment, clients} ->
        Process.demonitor(attachment.monitor, [:flush])
        state = %{state | clients: clients}

        case persist_ownership(state, Ownership.detach(state.ownership, client)) do
          {:ok, state} -> state
          _ -> finish(state, "protocol_error")
        end
    end
  end

  defp finish(%{terminal: terminal} = state, _reason, _details) when terminal != nil, do: state

  defp finish(state, reason, details) do
    close_port(state.port)
    Enum.each(state.waiters, &GenServer.reply(&1, {:error, :terminal_session_ended}))

    {state, log_result} = persist_log(state)
    reason = if log_result == :ok, do: reason, else: "artifact_failed"

    payload =
      Map.merge(%{"reason" => reason}, details)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    recorded =
      Events.append(
        state.request,
        "terminal.session.exited",
        payload,
        "terminal-exit:#{state.run_id}"
      )

    state = %{state | terminal: reason, phase: :ended, waiters: []}

    state =
      if reason == "exited" and match?({:ok, _}, recorded),
        do: add_event(state, :result, %{result: %{status: "interrupted", artifact_id: nil}}),
        else:
          add_event(state, :error, %{
            error:
              Error.new(
                :transport,
                "terminal_#{reason}",
                "Interactive terminal ended; inspect the recorded lifecycle and checkpoint."
              )
          })

    broadcast(state, {:terminal_status, public(state)})
    state
  end

  defp finish(state, reason), do: finish(state, reason, %{})

  defp persist_log(%{retain?: false} = state), do: {state, :ok}

  defp persist_log(state) do
    bytes = Shoestring.Cobbler.GateOutput.redact(state.log)

    case Shoestring.Trajectory.ArtifactStore.put(
           state.request.goal_id,
           bytes,
           %{media_type: "text/plain", redacted: true},
           task_id: state.request.task_id,
           max_size: @log_limit
         ) do
      {:ok, artifact} ->
        {add_event(%{state | log: <<>>}, :artifact, %{artifact_id: artifact.id}), :ok}

      _ ->
        {%{state | log: <<>>}, :error}
    end
  end

  defp add_event(state, kind, attrs) do
    ordinal = state.ordinal + 1

    {:ok, event} =
      HarnessEvent.new(
        Map.merge(
          %{
            version: 1,
            run_id: state.run_id,
            source_event_id: "terminal:#{state.run_id}:#{ordinal}",
            ordinal: ordinal,
            occurred_at: DateTime.utc_now(),
            kind: kind,
            extensions: %{}
          },
          attrs
        )
      )

    %{state | events: state.events ++ [event], ordinal: ordinal}
  end

  defp send_input(state, bytes) when is_binary(bytes) and byte_size(bytes) in 1..8192,
    do: command(state, session_command(state, "input", %{"data" => Base.encode64(bytes)}))

  defp send_input(_state, _bytes), do: {:error, :terminal_input_too_large}

  defp session_command(state, op, fields),
    do: Map.merge(fields, %{"op" => op, "session_id" => state.run_id})

  defp command(state, message) do
    with {:ok, frame} <- Protocol.encode(message),
         true <- Port.command(state.port, frame, [:nosuspend]) do
      :ok
    else
      _ -> {:error, :terminal_backpressure}
    end
  rescue
    ArgumentError -> {:error, :terminal_unavailable}
  end

  defp public(state),
    do: %{
      state: if(state.terminal, do: "ended", else: Atom.to_string(state.phase)),
      ownership: Ownership.public(state.ownership),
      reason: state.terminal
    }

  defp public(state, client) do
    attachment = state.clients[client]

    can_input =
      attachment != nil and state.terminal == nil and
        Ownership.human_input(state.ownership, attachment.browser, client) == :ok

    Map.put(public(state), :can_input, can_input)
  end

  defp broadcast(state, {:terminal_status, _}) do
    Enum.each(Map.keys(state.clients), fn client ->
      send(client, {:terminal_status, public(state, client)})
    end)
  end

  defp valid_browser?(browser), do: is_binary(browser) and byte_size(browser) == 32

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
