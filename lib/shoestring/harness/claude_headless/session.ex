defmodule Shoestring.Harness.ClaudeHeadless.Session do
  @moduledoc """
  Coordinates one one-shot `claude --print --verbose --output-format
  stream-json` run.

  Key responsibilities:

  - Spawns the child through `ClaudeHeadless.Transport` (or drives a
    caller-supplied transport double) and parses stdout as JSONL.
  - Buffers normalized events live as they arrive — no provider backfill
    exists for this protocol either.
  - Tracks tool boundaries by `toolu_` id: START (`assistant`/`tool_use`)
    adds the id to the in-flight set, END (`user`/`tool_result`) removes
    it. No alternation is assumed.
  - Cancellation is process-kill only. There is no in-band interrupt
    equivalent to Codex `turn/interrupt`, and the lease path does not
    pretend otherwise: a safe-boundary cancel defers the `killpg` until
    the in-flight set drains, then kills the whole owned process group.
  - Oversized lines fail closed (`:oversized_frame`): kill, reap, record
    a transport error. Oversized output is never silently truncated.
  - Terminal classification comes from the normalized `result` frame
    (`is_error` / `terminal_reason`); a nonzero exit or an exit without
    any `result` frame synthesizes an explicit transport error.
  - Identity callers park until the first frame carrying `session_id`
    sets the provider identity, so `start/2` never persists a nil
    placeholder; every terminal path (spawn failure, transport loss,
    child exit, cancellation, call timeout) releases parked callers,
    with an error when no session id was ever observed.

  The parser never crashes the session: undecodable lines are counted and
  ignored, and normalization runs under `try/rescue`.
  """

  use GenServer
  require Logger

  alias Shoestring.Harness.{Error, HarnessEvent}
  alias Shoestring.Harness.ClaudeHeadless.{EventNormalizer, Transport}

  @default_max_frame_size 262_144
  @default_request_timeout 15_000

  defstruct [
    :run_id,
    :run_request,
    :opts,
    :transport_mod,
    :transport_pid,
    :transport_ref,
    :transport_os_pid,
    :owner,
    :provider_session_id,
    :in_flight,
    :stop_requested,
    :buffered_events,
    :event_ordinal,
    :status,
    :terminal_result,
    :terminal_waiters,
    :identity_waiters,
    :malformed_lines,
    :exit_status,
    :max_frame_size
  ]

  # --- Public API ---

  @doc "Starts a new session process."
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Blocks until the provider session id is known from the first
  (`system/init`) frame and returns the normalized RunIdentity, or
  returns an error if the session terminalizes first (spawn failure,
  transport loss, child exit with no frames, cancellation) or the
  timeout elapses.

  Unlike `get_run_identity/1` (which returns the best identity known so
  far, possibly with a nil provider session), this is what `start/2`
  uses, so a started run's persisted identity always carries the real
  provider session id — never a placeholder nil.
  """
  @spec await_run_identity(GenServer.server(), timeout()) ::
          {:ok, Shoestring.Harness.RunIdentity.t()} | {:error, Error.t()}
  def await_run_identity(server, timeout \\ @default_request_timeout) do
    GenServer.call(server, :await_run_identity, timeout)
  catch
    :exit, {:timeout, _} ->
      {:error,
       Error.new(:transport, "identity_timeout", "Session did not answer identity in time")}

    :exit, reason ->
      {:error,
       Error.new(:transport, "session_crashed", "Session process exited: #{inspect(reason)}")}
  end

  @doc "Returns the normalized RunIdentity for this session."
  @spec get_run_identity(GenServer.server()) ::
          {:ok, Shoestring.Harness.RunIdentity.t()} | {:error, term()}
  def get_run_identity(server) do
    GenServer.call(server, :get_run_identity)
  end

  @doc "Returns the buffered stream of HarnessEvent structs."
  @spec stream_events(GenServer.server()) :: {:ok, [HarnessEvent.t()]}
  def stream_events(server) do
    GenServer.call(server, :stream_events)
  end

  @doc """
  Blocks until the one-shot run reaches a terminal state
  (`:completed`, `:failed`, or `:cancelled`), or the timeout elapses.
  """
  @spec await_terminal(GenServer.server(), timeout()) :: {:ok, map()} | {:error, Error.t()}
  def await_terminal(server, timeout \\ @default_request_timeout) do
    GenServer.call(server, :await_terminal, timeout)
  catch
    :exit, {:timeout, _} ->
      {:error, Error.new(:transport, "terminal_timeout", "Run did not terminate in time")}

    :exit, reason ->
      {:error,
       Error.new(:transport, "session_crashed", "Session process exited: #{inspect(reason)}")}
  end

  @doc """
  Cancels the running session by killing the whole owned process group.

  Options:

    * `:boundary` — when `:safe`, `:item`, `:lease` (or `:safe_boundary`),
      the kill is deferred until the in-flight tool set drains, so an
      in-flight command's `tool_result` is observed before the group is
      reaped. There is no in-band interrupt: deferred or not, cancellation
      always ends in `killpg`. By default (no boundary option) the group
      is killed immediately.
  """
  @spec cancel(GenServer.server(), keyword() | map()) :: {:ok, :cancelled} | {:error, Error.t()}
  def cancel(server, opts \\ %{}) do
    GenServer.call(server, {:cancel, opts}, @default_request_timeout)
  end

  @doc "Returns the current state and status map."
  @spec status(GenServer.server()) :: {:ok, map()}
  def status(server) do
    GenServer.call(server, :status)
  end

  # --- GenServer Callbacks ---

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    run_request = Keyword.get(opts, :run_request)
    run_id = Keyword.get(opts, :run_id) || (run_request && run_request.dispatch_id)
    owner = Keyword.get(opts, :owner) || self()
    transport_mod = Keyword.get(opts, :transport, Transport)
    configured_transport_pid = Keyword.get(opts, :transport_pid)
    max_frame_size = Keyword.get(opts, :max_frame_size, @default_max_frame_size)

    with {:ok, workdir} <- validate_workdir(Keyword.get(opts, :workdir)) do
      state = %__MODULE__{
        run_id: run_id,
        run_request: run_request,
        opts: Keyword.put(opts, :workdir, workdir),
        transport_mod: transport_mod,
        transport_pid: configured_transport_pid,
        transport_ref: nil,
        transport_os_pid: nil,
        owner: owner,
        provider_session_id: nil,
        in_flight: MapSet.new(),
        stop_requested: nil,
        buffered_events: [],
        event_ordinal: 0,
        status: :starting,
        terminal_result: nil,
        terminal_waiters: [],
        identity_waiters: [],
        malformed_lines: 0,
        exit_status: nil,
        max_frame_size: max_frame_size
      }

      {:ok, state, {:continue, :init_transport}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_continue(:init_transport, state) do
    if state.transport_pid do
      ref = Process.monitor(state.transport_pid)
      os_pid = get_os_pid(state.transport_mod, state.transport_pid)
      {:noreply, %{state | transport_ref: ref, transport_os_pid: os_pid, status: :running}}
    else
      argv =
        case Keyword.get(state.opts, :argv) do
          [head | _] = full when is_binary(head) -> full
          _ -> default_argv(state)
        end

      command = Keyword.get(state.opts, :command, hd(argv))
      args = Keyword.get(state.opts, :args, tl(argv))

      transport_opts =
        [
          owner: self(),
          max_frame_size: state.max_frame_size,
          command: command,
          args: args
        ]
        |> maybe_put_opt(:executable, Keyword.get(state.opts, :executable))
        |> maybe_put_opt(:cd, Keyword.get(state.opts, :workdir))
        |> maybe_put_opt(:env, Keyword.get(state.opts, :env))

      case state.transport_mod.start_link(transport_opts) do
        {:ok, pid} ->
          ref = Process.monitor(pid)
          os_pid = get_os_pid(state.transport_mod, pid)

          {:noreply,
           %{
             state
             | transport_pid: pid,
               transport_ref: ref,
               transport_os_pid: os_pid,
               status: :running
           }}

        {:error, reason} ->
          Logger.error("ClaudeHeadless: failed to spawn transport: #{inspect(reason)}")
          error = Error.new(:transport, "transport_spawn_failed", inspect(reason))
          state = %{state | status: :failed, terminal_result: {:error, error}}
          state = emit_synthetic_error(state, error)
          {:noreply, state |> reply_terminal_waiters() |> reply_identity_waiters()}
      end
    end
  end

  # --- Calls ---

  @impl GenServer
  def handle_call(:get_run_identity, _from, state) do
    {:reply, build_run_identity(state), state}
  end

  def handle_call(:await_run_identity, from, state) do
    cond do
      not is_nil(state.provider_session_id) ->
        {:reply, build_run_identity(state), state}

      terminal?(state) ->
        {:reply, identity_terminal_result(state), state}

      true ->
        {:noreply, %{state | identity_waiters: [from | state.identity_waiters]}}
    end
  end

  def handle_call(:stream_events, _from, state) do
    {:reply, {:ok, Enum.reverse(state.buffered_events)}, state}
  end

  def handle_call(:await_terminal, from, state) do
    if terminal?(state) do
      {:reply, {:ok, terminal_summary(state)}, state}
    else
      {:noreply, %{state | terminal_waiters: [from | state.terminal_waiters]}}
    end
  end

  def handle_call({:cancel, opts}, _from, state) do
    if terminal?(state) do
      {:reply, {:ok, :cancelled}, state}
    else
      opts_map = if is_list(opts), do: Map.new(opts), else: opts
      boundary = Map.get(opts_map, :boundary) || Map.get(opts_map, "boundary")

      if boundary in [:safe, :safe_boundary, :item, "item", :lease, "lease"] or
           Map.get(opts_map, :safe) == true do
        if MapSet.size(state.in_flight) > 0 do
          # Deferred kill: let the in-flight tools report, then reap the
          # group before the next tool starts. Kill-based throughout —
          # there is no turn/interrupt to issue.
          {:reply, {:ok, :cancelled}, %{state | stop_requested: :safe_boundary}}
        else
          state = do_kill(state)
          {:reply, {:ok, :cancelled}, state}
        end
      else
        state = do_kill(state)
        {:reply, {:ok, :cancelled}, state}
      end
    end
  end

  def handle_call(:status, _from, state) do
    {:reply, {:ok, status_summary(state)}, state}
  end

  # --- Transport messages ---

  @impl GenServer
  def handle_info({:claude_transport_connected, pid}, state) do
    ref = state.transport_ref || Process.monitor(pid)
    os_pid = state.transport_os_pid || get_os_pid(state.transport_mod, pid)

    {:noreply,
     %{state | transport_pid: pid, transport_ref: ref, transport_os_pid: os_pid, status: :running}}
  end

  def handle_info({:claude_transport_frame, _pid, line}, state) do
    if terminal?(state) do
      # Terminal guard: ignore frames after a terminal state.
      {:noreply, state}
    else
      {:noreply, handle_line(line, state)}
    end
  end

  def handle_info({:claude_transport_error, _pid, :oversized_frame}, state) do
    if terminal?(state) do
      {:noreply, state}
    else
      Logger.error("ClaudeHeadless: oversized frame detected at line cap; fail-closed.")
      state = do_kill(state)

      error =
        Error.new(
          :transport,
          "oversized_frame",
          "Line cap exceeded; transport rejected oversized payload"
        )

      state = %{state | status: :failed, terminal_result: {:error, error}}
      state = emit_synthetic_error(state, error)
      {:noreply, state |> reply_terminal_waiters() |> reply_identity_waiters()}
    end
  end

  def handle_info({:claude_transport_closed, _pid, reason}, state) do
    exit_status =
      case reason do
        {:exit_status, code} -> code
        _ -> nil
      end

    state = %{state | exit_status: exit_status}

    cond do
      state.status == :cancelled ->
        {:noreply, state |> reply_terminal_waiters() |> reply_identity_waiters()}

      terminal?(state) ->
        {:noreply, state |> reply_terminal_waiters() |> reply_identity_waiters()}

      exit_status == 0 ->
        # Exit 0 without a result frame: fail closed rather than
        # fabricating a completion.
        error =
          Error.new(:transport, "missing_result_frame", "Process exited 0 with no result frame")

        state = %{state | status: :failed, terminal_result: {:error, error}}
        state = emit_synthetic_error(state, error)
        {:noreply, state |> reply_terminal_waiters() |> reply_identity_waiters()}

      true ->
        error =
          Error.new(
            :transport,
            "nonzero_exit",
            "Process exited (#{inspect(exit_status)}) with no result frame"
          )

        state = %{state | status: :failed, terminal_result: {:error, error}}
        state = emit_synthetic_error(state, error)
        {:noreply, state |> reply_terminal_waiters() |> reply_identity_waiters()}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{transport_ref: ref} = state) do
    if terminal?(state) do
      {:noreply, %{state | transport_pid: nil, transport_ref: nil}}
    else
      error = Error.new(:transport, "transport_down", inspect(reason))

      state = %{
        state
        | transport_pid: nil,
          transport_ref: nil,
          status: :failed,
          terminal_result: {:error, error}
      }

      state = emit_synthetic_error(state, error)
      {:noreply, state |> reply_terminal_waiters() |> reply_identity_waiters()}
    end
  end

  def handle_info(_other, state) do
    {:noreply, state}
  end

  # --- Frame handling ---

  defp handle_line(line, state) do
    case Jason.decode(line) do
      {:ok, frame} when is_map(frame) ->
        handle_frame(frame, state)

      _ ->
        %{state | malformed_lines: state.malformed_lines + 1}
    end
  rescue
    _ -> %{state | malformed_lines: state.malformed_lines + 1}
  end

  defp handle_frame(frame, state) do
    try do
      case EventNormalizer.normalize(frame, state.run_id, state.event_ordinal + 1, %{
             process_id: state.transport_os_pid && to_string(state.transport_os_pid),
             provider_session_id: state.provider_session_id
           }) do
        {:ok, events} ->
          Enum.reduce(events, state, &ingest_event/2)

        {:skip, _reason} ->
          state

        {:error, reason} ->
          Logger.warning("ClaudeHeadless event normalization error: #{inspect(reason)}")
          state
      end
    rescue
      error ->
        Logger.warning("ClaudeHeadless normalizer raised: #{inspect(error)}")
        %{state | malformed_lines: state.malformed_lines + 1}
    end
  end

  defp ingest_event(%HarnessEvent{} = event, state) do
    state = buffer_event(state, event)
    state = track_session_id(state, event, event.extensions)
    state = track_tool_boundary(state, event)
    maybe_terminal(state, event)
  end

  defp buffer_event(state, %HarnessEvent{} = event) do
    %{state | buffered_events: [event | state.buffered_events], event_ordinal: event.ordinal}
  end

  defp track_session_id(state, _event, %{"claude-headless:session_id" => sid})
       when is_binary(sid) and sid != "" do
    cond do
      is_nil(state.provider_session_id) ->
        %{state | provider_session_id: sid}
        |> reply_identity_waiters()

      state.provider_session_id != sid ->
        Logger.warning("ClaudeHeadless: session_id changed mid-run; keeping the first")
        state

      true ->
        state
    end
  end

  defp track_session_id(state, _event, _ext), do: state

  defp track_tool_boundary(state, %HarnessEvent{extensions: ext}) do
    tool_id = ext["claude-headless:tool_use_id"]

    case {ext["claude-headless:boundary"], tool_id} do
      {"start", id} when is_binary(id) and id != "" ->
        state = %{state | in_flight: MapSet.put(state.in_flight, id)}
        maybe_drain_kill(state)

      {"end", id} when is_binary(id) and id != "" ->
        state = %{state | in_flight: MapSet.delete(state.in_flight, id)}
        maybe_drain_kill(state)

      _ ->
        state
    end
  end

  # Deferred safe-boundary kill: the in-flight set just drained while a
  # stop was requested — reap the group before the next tool starts.
  defp maybe_drain_kill(%{stop_requested: :safe_boundary} = state) do
    if MapSet.size(state.in_flight) == 0 and not terminal?(state) do
      do_kill(state)
    else
      state
    end
  end

  defp maybe_drain_kill(state), do: state

  defp maybe_terminal(state, %HarnessEvent{kind: :result} = event) do
    if event.extensions["claude-headless:terminal"] == true do
      %{state | status: :completed, terminal_result: {:ok, :completed}}
      |> reply_terminal_waiters()
      |> reply_identity_waiters()
    else
      state
    end
  end

  defp maybe_terminal(state, %HarnessEvent{kind: :error} = event) do
    if event.extensions["claude-headless:terminal"] == true do
      %{state | status: :failed, terminal_result: {:error, event.error}}
      |> reply_terminal_waiters()
      |> reply_identity_waiters()
    else
      state
    end
  end

  defp maybe_terminal(state, _event), do: state

  # --- Kill & synthetic errors ---

  # Kill-based cancel: SIGTERM → KILL escalation against the whole owned
  # process group, then reap. There is no in-band interrupt on this
  # protocol, so every cancellation path ends here.
  defp do_kill(state) do
    if state.transport_pid && Process.alive?(state.transport_pid) do
      try do
        state.transport_mod.terminate_group(state.transport_pid)
      catch
        _, _ -> :ok
      end
    end

    %{state | status: :cancelled, terminal_result: {:ok, :cancelled}}
    |> reply_terminal_waiters()
    |> reply_identity_waiters()
  end

  defp emit_synthetic_error(state, %Error{} = error) do
    ordinal = state.event_ordinal + 1

    event = %HarnessEvent{
      version: 1,
      run_id: state.run_id,
      source_event_id: "synthetic-error-#{ordinal}",
      ordinal: ordinal,
      occurred_at: DateTime.utc_now(),
      kind: :error,
      process_id: state.transport_os_pid && to_string(state.transport_os_pid),
      provider_session_id: state.provider_session_id,
      artifact_id: nil,
      capacity_snapshot_id: nil,
      error: error,
      result: nil,
      extensions: %{"claude-headless:synthetic" => true}
    }

    %{state | buffered_events: [event | state.buffered_events], event_ordinal: ordinal}
  end

  # --- Status & identity ---

  defp terminal?(%{status: status}), do: status in [:completed, :failed, :cancelled]

  defp status_summary(state) do
    %{
      status: state.status,
      provider_session_id: state.provider_session_id,
      in_flight: MapSet.to_list(state.in_flight),
      stop_requested: state.stop_requested,
      event_count: length(state.buffered_events),
      malformed_lines: state.malformed_lines,
      exit_status: state.exit_status
    }
  end

  defp terminal_summary(state) do
    state |> status_summary() |> Map.put(:terminal_result, state.terminal_result)
  end

  defp reply_terminal_waiters(%{terminal_waiters: []} = state), do: state

  defp reply_terminal_waiters(state) do
    if terminal?(state) do
      summary = terminal_summary(state)
      Enum.each(state.terminal_waiters, fn from -> GenServer.reply(from, {:ok, summary}) end)
      %{state | terminal_waiters: []}
    else
      state
    end
  end

  # Releases parked identity waiters. Called when the provider session id
  # is first observed (success) and on EVERY terminal transition (error
  # when no session id was ever observed, so no caller can hang and no
  # nil identity can leak into a persisted run). Safe to call when no
  # waiters are parked.
  defp reply_identity_waiters(%{identity_waiters: []} = state), do: state

  defp reply_identity_waiters(state) do
    result =
      if not is_nil(state.provider_session_id) do
        build_run_identity(state)
      else
        identity_terminal_result(state)
      end

    Enum.each(state.identity_waiters, fn from -> GenServer.reply(from, result) end)
    %{state | identity_waiters: []}
  end

  # Identity result for a session that terminalized before any session id
  # was observed: the terminal error when there is one, else a synthesized
  # identity_unavailable error (e.g. cancelled before the first frame).
  defp identity_terminal_result(state) do
    case state.terminal_result do
      {:error, %Error{} = err} ->
        {:error, err}

      _ ->
        {:error,
         Error.new(
           :transport,
           "identity_unavailable",
           "Session ended before the provider session id was observed"
         )}
    end
  end

  defp build_run_identity(state) do
    Shoestring.Harness.RunIdentity.new(%{
      run_id: state.run_id,
      harness_id: "claude_headless_stream_json",
      process_id:
        (state.transport_os_pid && to_string(state.transport_os_pid)) ||
          "os-pid-#{System.unique_integer([:positive])}",
      provider_session_id: state.provider_session_id
    })
  end

  defp default_argv(state) do
    prompt = (state.run_request && state.run_request.prompt) || "Execute task."
    tools = Keyword.get(state.opts, :tools, "Bash")

    argv = ["claude", "--print", "--verbose", "--output-format", "stream-json"]

    argv =
      if Keyword.get(state.opts, :permission_bypass, true) do
        argv ++ ["--dangerously-skip-permissions"]
      else
        argv
      end

    argv ++ ["--tools=#{tools}", prompt]
  end

  defp validate_workdir(nil), do: {:ok, nil}

  defp validate_workdir(dir) when is_binary(dir) do
    cond do
      dir == "" or String.contains?(dir, <<0>>) -> {:error, {:invalid_workdir, dir}}
      File.dir?(dir) -> {:ok, dir}
      true -> {:error, {:invalid_workdir, dir}}
    end
  end

  defp validate_workdir(other), do: {:error, {:invalid_workdir, other}}

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp get_os_pid(transport_mod, transport_pid) do
    if is_pid(transport_pid) and function_exported?(transport_mod, :os_pid, 1) do
      transport_mod.os_pid(transport_pid)
    else
      nil
    end
  end
end
