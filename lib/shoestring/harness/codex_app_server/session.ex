defmodule Shoestring.Harness.CodexAppServer.Session do
  @moduledoc """
  Coordinates one execution run targeting `codex app-server --stdio`.

  Key responsibilities:
  - Manages stdio JSON-RPC transport and executes handshake / start / turn sequence.
  - Buffers events live as they arrive (no backfill is possible from the provider).
  - Implements the Lease Safe-Boundary Rule:
    Open tool items are tracked by identity (`item.id`, falling back to
    `processId` for commands). A pending safe stop / safe cancel never
    interrupts while any tool item is open, and never on a tool completion
    alone: after the last open tool drains, the interrupt waits for positive
    model-control evidence (an agent-message delta/completion, a
    reasoning/thinking start or completion, a new turn start) or the natural
    terminal (`turn/completed`). Non-tool items (reasoning, agent messages,
    user messages) never open entries and their completions never close
    unrelated tools; unknown item types fail conservatively (they open an
    entry until their matching completion). At most one interrupt is ever
    sent per turn for pending safe stops/cancels.
  - Owns descendant process tracking and executes `killpg` + process reaping as a backstop
    after turn interruption.
  - Handles line cap overflow (`:oversized_frame`) fail-closed: cancels the turn, reaps
    processes, and records a transport error.
  """

  use GenServer
  require Logger

  alias Shoestring.Harness.{Error, HarnessEvent, RunIdentity}
  alias Shoestring.Harness.Capacity.Codex.StdioTransport
  alias Shoestring.Harness.CodexAppServer.EventNormalizer

  @default_max_frame_size 10_485_760
  @default_request_timeout 15_000
  @default_handshake_timeout_ms 15_000

  defstruct [
    :run_id,
    :run_request,
    :opts,
    :transport_mod,
    :transport_pid,
    :transport_ref,
    :transport_os_pid,
    :owner,
    :thread_id,
    :current_turn_id,
    # Identity-keyed open tool items (`tool_key/1` => raw item map). A
    # pending safe stop / safe cancel waits until this map drains AND
    # model-control evidence arrives; see `track_item_boundaries/3`.
    :open_tools,
    :in_flight_commands,
    :stop_requested,
    # One-shot latch per turn: a pending safe stop / safe cancel sends
    # `turn/interrupt` at most once. Reset on `turn/started`.
    :stop_interrupt_sent,
    :buffered_events,
    :event_ordinal,
    :malformed_lines,
    :status,
    :next_request_id,
    :pending_requests,
    :terminal_result,
    :max_frame_size,
    :handshake_timeout_ms,
    :handshake_timer,
    :auto_handshake,
    :identity_waiters,
    # When true, a supervising Elf owns the OS process group (Elf
    # `process_owner: :adapter`): it adopts the group after the handshake and
    # reaps it after the verdict, so this session must not tear the group
    # down on its own success path first.
    :elf_owned_process_group
  ]

  # --- Public API ---

  @doc "Starts a new session process."
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Blocks until the thread_id is known from the handshake and returns the RunIdentity,
  or returns an error if handshake fails or times out.
  """
  @spec await_run_identity(GenServer.server(), timeout()) ::
          {:ok, RunIdentity.t()} | {:error, Error.t()}
  def await_run_identity(server, timeout \\ @default_request_timeout) do
    GenServer.call(server, :await_run_identity, timeout)
  catch
    :exit, {:timeout, _} ->
      {:error,
       Error.new(
         :transport,
         "handshake_timeout",
         "Handshake failed to establish identity within #{timeout}ms"
       )}

    :exit, reason ->
      {:error,
       Error.new(
         :transport,
         "session_crashed",
         "Session process exited during handshake: #{inspect(reason)}"
       )}
  end

  @doc "Returns the normalized RunIdentity for this session."
  @spec get_run_identity(GenServer.server()) :: {:ok, RunIdentity.t()} | {:error, term()}
  def get_run_identity(server) do
    GenServer.call(server, :get_run_identity)
  end

  @doc "Returns the buffered stream of HarnessEvent structs."
  @spec stream_events(GenServer.server()) :: {:ok, [HarnessEvent.t()]}
  def stream_events(server) do
    GenServer.call(server, :stream_events)
  end

  @doc """
  Requests cancellation of the running session.

  Options:
  - `:boundary` - `:safe_boundary` (wait for current item.completed) or `:immediate` (default).
  """
  @spec cancel(GenServer.server(), keyword() | map()) :: {:ok, :cancelled} | {:error, Error.t()}
  def cancel(server, opts \\ %{}) do
    GenServer.call(server, {:cancel, opts}, @default_request_timeout)
  end

  @doc "Requests stopping at the next safe boundary (after in-flight item.completed)."
  @spec request_safe_stop(GenServer.server()) :: {:ok, :stop_requested}
  def request_safe_stop(server) do
    GenServer.call(server, :request_safe_stop)
  end

  @doc "Returns the current state and status map."
  @spec status(GenServer.server()) :: {:ok, map()}
  def status(server) do
    GenServer.call(server, :status)
  end

  @doc false
  @spec shutdown(GenServer.server()) :: :ok
  def shutdown(server) do
    GenServer.call(server, :shutdown, 30_000)
  catch
    :exit, _reason -> :ok
  end

  # --- GenServer Callbacks ---

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    run_request = Keyword.get(opts, :run_request)
    run_id = Keyword.get(opts, :run_id) || (run_request && run_request.dispatch_id)
    owner = Keyword.get(opts, :owner) || self()
    transport_mod = Keyword.get(opts, :transport, StdioTransport)
    configured_transport_pid = Keyword.get(opts, :transport_pid)
    max_frame_size = Keyword.get(opts, :max_frame_size, @default_max_frame_size)
    handshake_timeout_ms = Keyword.get(opts, :handshake_timeout_ms, @default_handshake_timeout_ms)
    auto_handshake = Keyword.get(opts, :auto_handshake, true)
    elf_owned_process_group = Keyword.get(opts, :elf_owned_process_group, false)

    state = %__MODULE__{
      run_id: run_id,
      run_request: run_request,
      opts: opts,
      transport_mod: transport_mod,
      transport_pid: configured_transport_pid,
      transport_ref: nil,
      transport_os_pid: nil,
      owner: owner,
      thread_id: Keyword.get(opts, :thread_id),
      current_turn_id: nil,
      open_tools: %{},
      in_flight_commands: %{},
      stop_requested: nil,
      stop_interrupt_sent: false,
      buffered_events: [],
      event_ordinal: 0,
      malformed_lines: 0,
      status: :starting,
      next_request_id: 1,
      pending_requests: %{},
      terminal_result: nil,
      max_frame_size: max_frame_size,
      handshake_timeout_ms: handshake_timeout_ms,
      handshake_timer: nil,
      auto_handshake: auto_handshake,
      identity_waiters: [],
      elf_owned_process_group: elf_owned_process_group
    }

    {:ok, state, {:continue, :init_transport}}
  end

  @impl GenServer
  def handle_continue(:init_transport, state) do
    if state.transport_pid do
      ref = Process.monitor(state.transport_pid)
      os_pid = get_os_pid(state.transport_mod, state.transport_pid)
      state = %{state | transport_ref: ref, transport_os_pid: os_pid}

      if state.auto_handshake do
        send(self(), {:codex_transport_connected, state.transport_pid})
      end

      {:noreply, state}
    else
      # Live path: spawn StdioTransport when :transport_pid is absent
      transport_opts =
        state.opts
        |> Keyword.get(:transport_opts, [])
        |> Keyword.merge(
          owner: self(),
          max_frame_size: state.max_frame_size
        )
        |> forward_opt(state.opts, :command)
        |> forward_opt(state.opts, :executable)
        |> forward_opt(state.opts, :args)

      case state.transport_mod.start_link(transport_opts) do
        {:ok, pid} ->
          ref = Process.monitor(pid)
          os_pid = get_os_pid(state.transport_mod, pid)
          {:noreply, %{state | transport_pid: pid, transport_ref: ref, transport_os_pid: os_pid}}

        {:error, reason} ->
          Logger.error("CodexAppServer: failed to spawn transport: #{inspect(reason)}")
          error = Error.new(:transport, "transport_spawn_failed", inspect(reason))
          state = %{state | status: :failed, terminal_result: {:error, error}}
          state = emit_synthetic_error(state, error)
          state = reply_identity_waiters(state, {:error, error})
          {:noreply, state}
      end
    end
  end

  # --- Calls ---

  @impl GenServer
  def handle_call(:await_run_identity, from, state) do
    cond do
      state.status == :failed ->
        reply =
          state.terminal_result ||
            {:error, Error.new(:transport, "session_failed", "Session failed during handshake")}

        {:reply, reply, state}

      state.status == :closed ->
        {:reply,
         {:error, Error.new(:transport, "session_closed", "Session closed during handshake")},
         state}

      state.thread_id != nil and
          state.status in [:turn_in_progress, :stopping, :completed, :interrupted] ->
        {:reply, build_run_identity(state), state}

      true ->
        {:noreply, %{state | identity_waiters: [from | state.identity_waiters]}}
    end
  end

  def handle_call(:get_run_identity, _from, state) do
    {:reply, build_run_identity(state), state}
  end

  def handle_call(:stream_events, _from, state) do
    {:reply, {:ok, Enum.reverse(state.buffered_events)}, state}
  end

  def handle_call({:cancel, opts}, _from, state) do
    opts_map = if is_list(opts), do: Map.new(opts), else: opts
    boundary = Map.get(opts_map, :boundary) || Map.get(opts_map, "boundary")

    if boundary in [:safe, :safe_boundary, :item, "item", :lease, "lease"] or
         Map.get(opts_map, :safe) == true do
      # Safe boundary stopping: pend until every open tool drains and
      # model-control evidence arrives (shared one-shot with safe stop).
      {_reply, state} = pend_or_send_safe_stop(state)
      {:reply, {:ok, :cancelled}, state}
    else
      # Immediate cancellation: interrupt now and reap the owned group.
      state = do_interrupt(state)
      # Reap any child processes
      reap_descendants(state)
      state = %{state | stop_requested: nil, stop_interrupt_sent: true}
      {:reply, {:ok, :cancelled}, state}
    end
  end

  def handle_call(:request_safe_stop, _from, state) do
    {reply, state} = pend_or_send_safe_stop(state)
    {:reply, reply, state}
  end

  def handle_call(:status, _from, state) do
    summary = %{
      status: state.status,
      thread_id: state.thread_id,
      turn_id: state.current_turn_id,
      in_flight_item: representative_open_tool(state.open_tools),
      open_tool_count: map_size(state.open_tools),
      stop_requested: state.stop_requested,
      event_count: length(state.buffered_events),
      malformed_lines: state.malformed_lines
    }

    {:reply, {:ok, summary}, state}
  end

  def handle_call(:shutdown, _from, state) do
    reap_descendants(state)
    close_owned_transport(state)
    {:stop, :normal, :ok, state}
  end

  # Shared safe-stop decision: pend while tools are open (or no turn is
  # addressable yet); send exactly once when nothing is open at request
  # time. Later boundaries complete via `maybe_send_pending_stop/2`.
  defp pend_or_send_safe_stop(state) do
    cond do
      terminal_status?(state.status) ->
        {{:ok, :stop_requested}, state}

      state.stop_interrupt_sent ->
        {{:ok, :stop_requested}, state}

      map_size(state.open_tools) > 0 ->
        {{:ok, :stop_requested}, %{state | stop_requested: :safe_boundary}}

      state.thread_id != nil and state.current_turn_id != nil ->
        state =
          state
          |> do_interrupt()
          |> Map.merge(%{stop_requested: nil, stop_interrupt_sent: true})

        {{:ok, :stop_requested}, state}

      true ->
        # No turn addressable yet: pend so the stop is honored at the
        # first safe moment instead of being silently dropped.
        {{:ok, :stop_requested}, %{state | stop_requested: :safe_boundary}}
    end
  end

  # Sends the pending safe interrupt exactly once, and only on
  # model-control evidence with no open tools. Tool completions that drain
  # the map deliberately do NOT send here: the provider may have already
  # emitted the next tool START (compound exec), which re-opens the map
  # before any evidence can fire.
  defp maybe_send_pending_stop(state, evidence?) do
    if evidence? and state.stop_requested == :safe_boundary and
         not state.stop_interrupt_sent and map_size(state.open_tools) == 0 and
         state.thread_id != nil and state.current_turn_id != nil do
      state
      |> do_interrupt()
      |> Map.merge(%{stop_requested: nil, stop_interrupt_sent: true})
    else
      state
    end
  end

  # --- Transport Notifications & Handshake ---

  @impl GenServer
  def handle_info({:codex_transport_connected, pid}, state) do
    ref = if state.transport_ref, do: state.transport_ref, else: Process.monitor(pid)
    os_pid = state.transport_os_pid || get_os_pid(state.transport_mod, pid)

    timer =
      if state.handshake_timer do
        state.handshake_timer
      else
        Process.send_after(self(), :handshake_timeout, state.handshake_timeout_ms)
      end

    state = %{
      state
      | transport_pid: pid,
        transport_ref: ref,
        transport_os_pid: os_pid,
        handshake_timer: timer
    }

    # Send initialize request
    state =
      send_rpc(
        state,
        "initialize",
        %{
          "clientInfo" => %{
            "name" => "shoestring_codex_adapter",
            "title" => "Shoestring Codex Execution Adapter",
            "version" => "0.1.0"
          }
        },
        :handshake_initialize
      )

    {:noreply, state}
  end

  def handle_info(:handshake_timeout, state) do
    if state.status == :turn_in_progress or
         (state.thread_id != nil and state.opts[:resume]) do
      {:noreply, %{state | handshake_timer: nil}}
    else
      Logger.error("CodexAppServer: handshake timed out after #{state.handshake_timeout_ms}ms")

      error =
        Error.new(
          :transport,
          "handshake_timeout",
          "Handshake failed to complete within #{state.handshake_timeout_ms}ms"
        )

      state = %{state | status: :failed, terminal_result: {:error, error}, handshake_timer: nil}
      state = emit_synthetic_error(state, error)
      reap_descendants(state)
      state = reply_identity_waiters(state, {:error, error})
      {:noreply, state}
    end
  end

  def handle_info({:codex_transport_frame, _pid, line}, state) do
    if state.status in [:failed, :closed, :interrupted, :completed] do
      # Terminal guard: ignore subsequent frames after terminal status (Nit 3)
      {:noreply, state}
    else
      case Jason.decode(line) do
        {:ok, frame} when is_map(frame) ->
          # Defensive: the provider offers no backfill, so a single
          # unparseable frame must never take down the Session and lose the
          # live-buffered events. Log and skip the frame, count it, keep
          # the session alive — mirroring
          # `Shoestring.Harness.ClaudeHeadless.Session.handle_frame/2`.
          # The net covers normalization AND raw-frame boundary tracking
          # together: a frame that fails to normalize is not cleanly
          # interpretable, so its boundary half is skipped as well.
          state =
            try do
              handle_rpc_frame(frame, state)
            rescue
              error ->
                Logger.warning(
                  "CodexAppServer frame handling raised: #{inspect(error)}; skipping frame"
                )

                %{state | malformed_lines: state.malformed_lines + 1}
            end

          {:noreply, state}

        {:ok, _non_map} ->
          Logger.warning("CodexAppServer received non-object frame; skipping")
          {:noreply, %{state | malformed_lines: state.malformed_lines + 1}}

        {:error, reason} ->
          Logger.warning("CodexAppServer received malformed frame: #{inspect(reason)}")
          {:noreply, %{state | malformed_lines: state.malformed_lines + 1}}
      end
    end
  end

  def handle_info({:codex_transport_error, _pid, :oversized_frame}, state) do
    Logger.error("CodexAppServer: oversized frame detected at line cap; fail-closed.")
    cancel_handshake_timer(state)
    # Fail-closed: interrupt turn, reap processes, emit error event
    state = do_interrupt(state)
    reap_descendants(state)

    error =
      Error.new(
        :transport,
        "oversized_frame",
        "Line cap exceeded; transport rejected oversized payload"
      )

    state = emit_synthetic_error(state, error)
    state = reply_identity_waiters(state, {:error, error})

    {:noreply,
     %{
       state
       | status: :failed,
         terminal_result: {:error, error},
         stop_requested: nil,
         stop_interrupt_sent: true
     }}
  end

  def handle_info({:codex_transport_closed, _pid, reason}, state) do
    cancel_handshake_timer(state)

    if terminal_status?(state.status) do
      {:noreply, %{state | transport_pid: nil, transport_ref: nil}}
    else
      reap_descendants(state)
      error = Error.new(:transport, "transport_closed", inspect(reason))
      state = emit_synthetic_error(state, error)
      state = reply_identity_waiters(state, {:error, error})

      {:noreply,
       %{
         state
         | transport_pid: nil,
           transport_ref: nil,
           status: :failed,
           terminal_result: {:error, error}
       }}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{transport_ref: ref} = state) do
    cancel_handshake_timer(state)

    if terminal_status?(state.status) do
      {:noreply, %{state | transport_pid: nil, transport_ref: nil}}
    else
      reap_descendants(state)
      error = Error.new(:transport, "transport_down", inspect(reason))
      state = emit_synthetic_error(state, error)
      state = reply_identity_waiters(state, {:error, error})

      {:noreply,
       %{
         state
         | transport_pid: nil,
           transport_ref: nil,
           status: :failed,
           terminal_result: {:error, error}
       }}
    end
  end

  def handle_info(_other, state) do
    {:noreply, state}
  end

  # --- RPC Protocol Logic ---

  defp handle_rpc_frame(%{"id" => id, "error" => err}, state)
       when not is_nil(id) and not is_nil(err) do
    cancel_handshake_timer(state)

    case Map.pop(state.pending_requests, id) do
      {{tag, _params}, remaining} ->
        Logger.error("CodexAppServer RPC error on #{inspect(tag)}: #{inspect(err)}")

        message = if is_map(err), do: err["message"] || inspect(err), else: inspect(err)

        error =
          Error.new(
            :transport,
            "rpc_error",
            "#{inspect(tag)} failed: #{message}"
          )

        state = %{
          state
          | pending_requests: remaining,
            status: :failed,
            terminal_result: {:error, error}
        }

        state = emit_synthetic_error(state, error)
        reap_descendants(state)
        reply_identity_waiters(state, {:error, error})

      {nil, _} ->
        state
    end
  end

  defp handle_rpc_frame(%{"id" => id} = response, state) when not is_nil(id) do
    # Correlation of responses
    case Map.pop(state.pending_requests, id) do
      {nil, _} ->
        state

      {{:handshake_initialize, _}, remaining} ->
        state = %{state | pending_requests: remaining}
        # Send initialized notification
        send_notification(state, "initialized", %{})

        # Send thread/start (or thread/resume if resuming)
        if state.opts[:resume] && state.thread_id do
          send_rpc(state, "thread/resume", %{"threadId" => state.thread_id}, :thread_resume)
        else
          cwd =
            state.opts[:workdir] || (state.run_request && state.run_request.workspace_ref) ||
              "/tmp"

          # NOTE on ephemeral: false (Required for thread/resume):
          # Codex only persists rollout files on disk (~/.codex/sessions) for non-ephemeral threads.
          # Consequently, every Elf run writes a rollout file to local user storage.
          # Because task prompts flow verbatim into rollouts outside Shoestring's trajectory store
          # and normalizer scrubbing, prompts MUST stay credential-free.
          # Furthermore, rollouts are vendor-written transcripts that may contain raw model reasoning
          # or scratchpads, and currently accumulate without automated retention bounds
          # (follow-up tracked for thread/archive or periodic cleanup).
          send_rpc(
            state,
            "thread/start",
            %{
              "cwd" => cwd,
              "ephemeral" => false,
              "approvalPolicy" => "never",
              "sandbox" => "workspace-write"
            },
            :thread_start
          )
        end

      {{:thread_start, _}, remaining} ->
        state = %{state | pending_requests: remaining}
        thread_id = get_in(response, ["result", "thread", "id"])
        state = %{state | thread_id: thread_id}
        # Now launch the turn
        prompt = (state.run_request && state.run_request.prompt) || "Execute task."

        send_rpc(
          state,
          "turn/start",
          %{
            "threadId" => thread_id,
            "input" => [%{"type" => "text", "text" => prompt}]
          },
          :turn_start
        )

      {{:thread_resume, _}, remaining} ->
        state = %{state | pending_requests: remaining}
        # Resumed! Launch turn with the continuation actually sent: the
        # original prompt plus the checkpoint pointer, next action, and
        # decision refs (the 3 continuation keys only; raw transcript
        # terms never enter).
        prompt = resume_turn_text(state.run_request)

        send_rpc(
          state,
          "turn/start",
          %{
            "threadId" => state.thread_id,
            "input" => [%{"type" => "text", "text" => prompt}]
          },
          :turn_start
        )

      {{:turn_start, _}, remaining} ->
        turn_id = get_in(response, ["result", "turn", "id"])
        cancel_handshake_timer(state)

        state = %{
          state
          | pending_requests: remaining,
            current_turn_id: turn_id,
            status: :turn_in_progress,
            handshake_timer: nil
        }

        # Handshake and turn launch complete: reply to any awaiting callers
        reply_identity_waiters(state, build_run_identity(state))

      {{:turn_interrupt, _}, remaining} ->
        # Interrupt acknowledged
        %{state | pending_requests: remaining, status: :stopping}

      {_other_req, remaining} ->
        %{state | pending_requests: remaining}
    end
  end

  defp handle_rpc_frame(%{"method" => method} = frame, state) do
    # Server push notification. The frame is normalized and buffered BEFORE
    # boundary tracking runs: `track_item_boundaries("turn/completed", ...)`
    # reaps the owned process group, and durable evidence of what happened
    # must already exist before any teardown. The completed item events and
    # the turn outcome therefore always precede the reap, so a lease-boundary
    # or explicit stop preserves the work instead of destroying it first.
    state = normalize_and_buffer(frame, state)
    track_item_boundaries(method, frame, state)
  end

  defp handle_rpc_frame(_other, state), do: state

  # --- Safe Boundary & Item Tracking ---
  #
  # Open tools are keyed by identity so unrelated completions can never
  # close them: `item.id` when present, else the command `processId`, else
  # a fresh anonymous key that only the natural terminal clears (fail
  # closed). Completions delete by key and therefore no-op for ids that
  # were never opened — including reasoning/thinking/agentMessage items,
  # which never open entries in the first place.

  # Item types that are model or user content, never mutating tools. They
  # neither open safe-boundary entries nor (as completions) close them.
  # Anything else — commandExecution, fileChange, present or future MCP
  # tool shapes, or a missing type — is potentially mutating and tracked
  # conservatively until its matching completion.
  @non_tool_item_types ["reasoning", "thought", "thinking", "agentMessage", "userMessage"]

  # Item types whose activity proves the model (not a tool) holds control.
  # Gated on an empty open-tool map, they release a pending safe stop.
  # Deltas stream while the model generates text; completions mark a
  # finished message or thought. A message START alone is not evidence:
  # commentary routinely precedes the next tool call in the same response.
  @model_control_item_types ["reasoning", "thought", "thinking", "agentMessage"]

  defp tool_item?(item) when is_map(item) do
    item["type"] not in @non_tool_item_types
  end

  defp tool_key(item) when is_map(item) do
    cond do
      is_binary(item["id"]) and item["id"] != "" -> {:id, item["id"]}
      item["processId"] != nil -> {:pid, to_string(item["processId"])}
      true -> {:anon, System.unique_integer([:positive, :monotonic])}
    end
  end

  # Legacy-compat view of the open-tool map for status readers (notably
  # the live-eval driver): the deterministically-first open item, or nil.
  defp representative_open_tool(open_tools) when map_size(open_tools) == 0, do: nil

  defp representative_open_tool(open_tools) do
    open_tools |> Enum.min_by(fn {key, _item} -> key end) |> elem(1)
  end

  defp track_item_boundaries("turn/started", frame, state) do
    turn_id = get_in(frame, ["params", "turn", "id"])

    state = %{
      state
      | current_turn_id: turn_id,
        status: :turn_in_progress,
        stop_interrupt_sent: false
    }

    # A stop requested before the turn became addressable is honored at
    # the first safe moment: nothing is observably in flight yet.
    maybe_send_pending_stop(state, true)
  end

  defp track_item_boundaries("item/started", frame, state) do
    item = get_in(frame, ["params", "item"]) || %{}
    cmd_pid = item["processId"]

    commands =
      if item["type"] == "commandExecution" and cmd_pid != nil do
        Map.put(state.in_flight_commands, cmd_pid, item)
      else
        state.in_flight_commands
      end

    open_tools =
      if tool_item?(item) do
        Map.put(state.open_tools, tool_key(item), item)
      else
        state.open_tools
      end

    state = %{state | open_tools: open_tools, in_flight_commands: commands}
    maybe_send_pending_stop(state, item["type"] in ["reasoning", "thought", "thinking"])
  end

  defp track_item_boundaries("item/completed", frame, state) do
    item = get_in(frame, ["params", "item"]) || %{}
    cmd_pid = item["processId"]

    commands =
      if cmd_pid != nil do
        Map.delete(state.in_flight_commands, cmd_pid)
      else
        state.in_flight_commands
      end

    # Identity-keyed close: an unrelated completion (reasoning, message,
    # or a different tool) cannot clear an open tool. Draining the last
    # entry only arms the pending stop — it never sends: the next tool
    # START may already be on its way (compound exec).
    state = %{
      state
      | open_tools: Map.delete(state.open_tools, tool_key(item)),
        in_flight_commands: commands
    }

    maybe_send_pending_stop(state, item["type"] in @model_control_item_types)
  end

  # Streaming text proves model control (with an empty open-tool map the
  # model is generating tokens, not executing a tool).
  defp track_item_boundaries("item/agentMessage/delta", _frame, state) do
    maybe_send_pending_stop(state, true)
  end

  defp track_item_boundaries("turn/completed", frame, state) do
    turn = get_in(frame, ["params", "turn"]) || %{}
    turn_status = turn["status"]

    # Single-turn session lifecycle cleanup (Nit 6):
    # Once turn/completed arrives, this Elf execution turn is finished. Because this session
    # oversees a single turn, we reap any background child processes and terminate the app-server
    # transport OS process to ensure clean teardown without lingering resources.
    #
    # Exception: when a supervising Elf owns the process group
    # (`elf_owned_process_group: true`), teardown is the Elf's job — it adopts
    # the group after the handshake and killpg-reaps it after the verdict
    # lands. Reaping here would kill the transport between the Elf's identity
    # await and its group-leader verify, failing launch as
    # `group_leader_unverifiable` under scheduler pressure. The turn outcome is
    # already buffered above, so the Elf still observes the full evidence.
    unless state.elf_owned_process_group do
      reap_descendants(state)
    end

    status =
      case turn_status do
        "interrupted" -> :interrupted
        "failed" -> :failed
        _ -> :completed
      end

    # Natural terminal resolves any pending safe stop without an
    # interrupt: the turn is over, so there is nothing left to stop.
    %{state | status: status, current_turn_id: nil, open_tools: %{}, stop_requested: nil}
  end

  defp track_item_boundaries(_method, _frame, state), do: state

  # --- Normalization and Buffering ---

  defp normalize_and_buffer(frame, state) do
    ordinal = state.event_ordinal + 1

    opts = %{
      process_id: state.transport_os_pid && to_string(state.transport_os_pid),
      provider_session_id: state.thread_id
    }

    case EventNormalizer.normalize(frame, state.run_id, ordinal, opts) do
      {:ok, %HarnessEvent{} = event} ->
        %{
          state
          | buffered_events: [event | state.buffered_events],
            event_ordinal: ordinal
        }

      {:skip, _reason} ->
        state

      {:error, reason} ->
        # Unparseable but non-raising: still evidence of stream shape
        # drift, so log it and count it alongside outright malformed
        # frames. Raising shapes propagate to the handle_info backstop,
        # which counts them there — exactly one count per frame either way.
        Logger.warning("CodexAppServer event normalization error: #{inspect(reason)}")
        %{state | malformed_lines: state.malformed_lines + 1}
    end
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
      provider_session_id: state.thread_id,
      artifact_id: nil,
      capacity_snapshot_id: nil,
      error: error,
      result: nil,
      extensions: %{"codex-app-server:synthetic" => true}
    }

    %{
      state
      | buffered_events: [event | state.buffered_events],
        event_ordinal: ordinal
    }
  end

  # --- Interrupt & Descendant Cleanup ---

  defp do_interrupt(state) do
    if state.thread_id && state.current_turn_id do
      send_rpc(
        state,
        "turn/interrupt",
        %{
          "threadId" => state.thread_id,
          "turnId" => state.current_turn_id
        },
        :turn_interrupt
      )
    else
      state
    end
  end

  # Descendant process reaping (Nit 5):
  # Assumes transport OS pid is group leader (pgid == os_pid). Command processIds
  # reported in item/started frames inherit the app-server's pgid, so calling kill -pid
  # for child is safe/harmless on both macOS and Linux, while transport-level killpg
  # (-transport_os_pid) reaps the entire process tree.
  defp reap_descendants(state) do
    # 1. Kill tracked child command pids
    Enum.each(state.in_flight_commands, fn {pid_str, _item} ->
      kill_process_and_group(pid_str)
    end)

    # 2. Kill app-server process group if terminating
    if state.transport_os_pid do
      kill_process_and_group(state.transport_os_pid)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp close_owned_transport(state) do
    if ((is_nil(state.opts[:transport_pid]) and state.transport_pid) &&
          Process.alive?(state.transport_pid)) and
         function_exported?(state.transport_mod, :close, 1) do
      state.transport_mod.close(state.transport_pid)
    end

    :ok
  catch
    _, _ -> :ok
  end

  defp kill_process_and_group(nil), do: :ok

  defp kill_process_and_group(pid_val) do
    pid =
      cond do
        is_integer(pid_val) -> pid_val
        is_binary(pid_val) -> String.to_integer(pid_val)
        true -> nil
      end

    if pid && pid > 1 do
      # Send SIGTERM to process group and pid
      _ = System.cmd("kill", ["-TERM", "-#{pid}"], stderr_to_stdout: true)
      _ = System.cmd("kill", ["-TERM", "#{pid}"], stderr_to_stdout: true)

      # Brief grace period check
      case System.cmd("kill", ["-0", "#{pid}"], stderr_to_stdout: true) do
        {_, 0} ->
          _ = System.cmd("kill", ["-KILL", "-#{pid}"], stderr_to_stdout: true)
          _ = System.cmd("kill", ["-KILL", "#{pid}"], stderr_to_stdout: true)

        _ ->
          :ok
      end
    end
  rescue
    _ -> :ok
  end

  # --- Helpers & RPC Management ---

  defp build_run_identity(state) do
    run_id = state.run_id
    process_id = state.transport_os_pid && to_string(state.transport_os_pid)
    session_id = state.thread_id

    RunIdentity.new(%{
      run_id: run_id,
      harness_id: "codex_app_server_stdio",
      process_id: process_id || "os-pid-#{System.unique_integer([:positive])}",
      provider_session_id: session_id || "session-#{run_id}"
    })
  end

  defp reply_identity_waiters(state, result) do
    Enum.each(state.identity_waiters, fn from ->
      GenServer.reply(from, result)
    end)

    %{state | identity_waiters: []}
  end

  defp cancel_handshake_timer(%{handshake_timer: ref}) when is_reference(ref) do
    Process.cancel_timer(ref)
  end

  defp cancel_handshake_timer(_), do: :ok

  defp forward_opt(opts, source_opts, key) do
    case Keyword.fetch(source_opts, key) do
      {:ok, val} -> Keyword.put_new(opts, key, val)
      :error -> opts
    end
  end

  # Turn input for a resumed thread (P4): the original prompt plus the
  # continuation content. Only the three continuation keys
  # (`checkpoint_id`/`next_action`/`decision_refs`) are read, so raw
  # transcript terms never enter. Fresh starts keep the plain prompt.
  defp resume_turn_text(nil), do: "Continue task."

  defp resume_turn_text(%{prompt: prompt, continuation: nil}) when is_binary(prompt),
    do: prompt

  defp resume_turn_text(%{prompt: prompt, continuation: continuation} = _request)
       when is_binary(prompt) do
    case continuation_text(continuation) do
      nil -> prompt
      suffix -> prompt <> "\n\n[Resume from checkpoint " <> suffix
    end
  end

  defp resume_turn_text(%{prompt: prompt}) when is_binary(prompt), do: prompt
  defp resume_turn_text(_request), do: "Continue task."

  defp continuation_text(nil), do: nil

  defp continuation_text(continuation) when is_map(continuation) do
    checkpoint_id = continuation[:checkpoint_id] || continuation["checkpoint_id"]
    next_action = continuation[:next_action] || continuation["next_action"]
    refs = continuation[:decision_refs] || continuation["decision_refs"] || []

    if is_binary(checkpoint_id) and is_binary(next_action) do
      refs_text =
        case Enum.filter(List.wrap(refs), &is_binary/1) do
          [] -> "none"
          list -> Enum.join(list, ", ")
        end

      "#{checkpoint_id}]\nNext action: #{next_action}\nDecision refs: #{refs_text}"
    else
      nil
    end
  end

  defp continuation_text(_continuation), do: nil

  defp send_rpc(state, method, params, tag) do
    id = state.next_request_id
    payload = %{"method" => method, "id" => id, "params" => params}

    if state.transport_pid do
      state.transport_mod.send_frame(state.transport_pid, payload)
    end

    %{
      state
      | next_request_id: id + 1,
        pending_requests: Map.put(state.pending_requests, id, {tag, params})
    }
  end

  defp send_notification(state, method, params) do
    payload = %{"method" => method, "params" => params}

    if state.transport_pid do
      state.transport_mod.send_frame(state.transport_pid, payload)
    end

    state
  end

  defp get_os_pid(transport_mod, transport_pid) do
    if function_exported?(transport_mod, :os_pid, 1) do
      transport_mod.os_pid(transport_pid)
    else
      nil
    end
  end

  defp terminal_status?(status), do: status in [:completed, :interrupted, :failed]
end
