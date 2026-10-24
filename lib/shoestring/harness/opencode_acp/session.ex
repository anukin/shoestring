defmodule Shoestring.Harness.OpencodeAcp.Session do
  @moduledoc """
  Coordinates one execution run over `opencode acp` (Agent Client Protocol,
  JSON-RPC 2.0 over stdio, one object per line).

  Sequence (VERIFIED against opencode 2.0.31 up to the prompt):
  `initialize` → `session/new` (or `session/resume`) →
  `session/set_config_option` for the model (and effort when the role pins
  one) → `session/prompt`. The prompt's response is the turn outcome;
  `session/update` notifications stream the work while it runs. The prompt
  stream shapes are SCHEMA-ONLY (see `EventNormalizer`).

  - Events are normalized and buffered live; there is no provider backfill.
  - ACP streams agent messages only as chunks, so a message's completion is
    emitted when the next tool call starts or the prompt returns.
  - Permission requests are answered by a fixed policy, never by model
    output: allowed once when the run is OS-sandboxed (the sandbox is the
    authority, as with Claude's sandboxed Bash), rejected otherwise.
  - A lease safe stop or safe cancel only pends; the prompt outcome resolves
    it. Explicit cancellation sends `session/cancel` and reaps the whole
    process tree at once (`ProcessTree`), because opencode's server child
    leads its own process group.
  - An oversized frame fails the run closed.
  """

  use GenServer
  require Logger

  alias Shoestring.Harness.{Continuation, Error, HarnessEvent, RunIdentity}
  alias Shoestring.Harness.Capacity.Codex.StdioTransport
  alias Shoestring.Harness.OpencodeAcp.{EventNormalizer, ProcessTree}

  @default_max_frame_size 10_485_760
  @default_request_timeout 15_000
  @default_handshake_timeout_ms 30_000
  @protocol_version 1

  defstruct [
    :run_id,
    :run_request,
    :opts,
    :transport_mod,
    :transport_pid,
    :transport_ref,
    :transport_os_pid,
    :session_id,
    :prompt_id,
    :status,
    :terminal_result,
    :stop_requested,
    :cancel_requested,
    :handshake_timer,
    :elf_owned_process_group,
    :message,
    tool_kinds: %{},
    buffered_events: [],
    event_ordinal: 0,
    malformed_lines: 0,
    next_request_id: 1,
    pending_requests: %{},
    identity_waiters: []
  ]

  # --- Public API ---

  @doc "Starts a session process."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Blocks until the prompt has been sent and returns the RunIdentity, or an
  error when the handshake fails or times out.
  """
  @spec await_run_identity(GenServer.server(), timeout()) ::
          {:ok, RunIdentity.t()} | {:error, Error.t()}
  def await_run_identity(server, timeout \\ @default_request_timeout) do
    GenServer.call(server, :await_run_identity, timeout)
  catch
    :exit, {:timeout, _} ->
      {:error,
       Error.new(:transport, "handshake_timeout", "Handshake did not finish within #{timeout}ms")}

    :exit, reason ->
      {:error,
       Error.new(
         :transport,
         "session_crashed",
         "Session exited during handshake: #{inspect(reason)}"
       )}
  end

  @doc "Returns the buffered normalized events."
  @spec stream_events(GenServer.server()) :: {:ok, [HarnessEvent.t()]}
  def stream_events(server), do: GenServer.call(server, :stream_events)

  @doc """
  Cancels the run. With `boundary: :safe | :item | :lease` (or `safe: true`)
  it pends like a safe stop; otherwise it cancels and reaps now.
  """
  @spec cancel(GenServer.server(), keyword() | map()) :: {:ok, :cancelled}
  def cancel(server, opts \\ %{}),
    do: GenServer.call(server, {:cancel, opts}, @default_request_timeout)

  @doc "Requests a lease safe stop. Always pends; the prompt outcome resolves it."
  @spec request_safe_stop(GenServer.server()) :: {:ok, :stop_requested}
  def request_safe_stop(server), do: GenServer.call(server, :request_safe_stop)

  @doc "Returns the current status summary."
  @spec status(GenServer.server()) :: {:ok, map()}
  def status(server), do: GenServer.call(server, :status)

  @doc false
  @spec shutdown(GenServer.server()) :: :ok
  def shutdown(server) do
    GenServer.call(server, :shutdown, 30_000)
  catch
    :exit, _reason -> :ok
  end

  # --- GenServer ---

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    request = Keyword.get(opts, :run_request)

    state = %__MODULE__{
      run_id: Keyword.get(opts, :run_id) || (request && request.dispatch_id),
      run_request: request,
      opts: opts,
      transport_mod: Keyword.get(opts, :transport, StdioTransport),
      transport_pid: Keyword.get(opts, :transport_pid),
      session_id: Keyword.get(opts, :session_id),
      status: :starting,
      elf_owned_process_group: Keyword.get(opts, :elf_owned_process_group, false)
    }

    {:ok, state, {:continue, :init_transport}}
  end

  @impl GenServer
  def handle_continue(:init_transport, %{transport_pid: pid} = state) when is_pid(pid) do
    state = %{state | transport_ref: Process.monitor(pid), transport_os_pid: os_pid(state, pid)}
    send(self(), {:codex_transport_connected, pid})
    {:noreply, state}
  end

  def handle_continue(:init_transport, state) do
    transport_opts =
      [
        owner: self(),
        max_frame_size: Keyword.get(state.opts, :max_frame_size, @default_max_frame_size),
        command: Keyword.get(state.opts, :command, "opencode"),
        args: Keyword.get(state.opts, :args, ["acp"]),
        env: Keyword.get(state.opts, :env, [])
      ]
      |> then(fn opts ->
        case Keyword.get(state.opts, :executable) do
          nil -> opts
          path -> Keyword.put(opts, :executable, path)
        end
      end)

    case state.transport_mod.start_link(transport_opts) do
      {:ok, pid} ->
        {:noreply,
         %{
           state
           | transport_pid: pid,
             transport_ref: Process.monitor(pid),
             transport_os_pid: os_pid(state, pid)
         }}

      {:error, reason} ->
        {:noreply, fail(state, Error.new(:transport, "transport_spawn_failed", inspect(reason)))}
    end
  end

  # --- Calls ---

  @impl GenServer
  def handle_call(:await_run_identity, from, state) do
    cond do
      state.status == :failed and state.prompt_id == nil ->
        {:reply, state.terminal_result, state}

      state.prompt_id != nil ->
        {:reply, run_identity(state), state}

      true ->
        {:noreply, %{state | identity_waiters: [from | state.identity_waiters]}}
    end
  end

  def handle_call(:stream_events, _from, state),
    do: {:reply, {:ok, Enum.reverse(state.buffered_events)}, state}

  def handle_call({:cancel, opts}, _from, state) do
    opts = Map.new(opts)
    boundary = Map.get(opts, :boundary) || Map.get(opts, "boundary")

    if boundary in [:safe, :safe_boundary, :item, "item", :lease, "lease"] or
         Map.get(opts, :safe) == true do
      {:reply, {:ok, :cancelled}, pend_safe_stop(state)}
    else
      {:reply, {:ok, :cancelled}, cancel_now(state)}
    end
  end

  def handle_call(:request_safe_stop, _from, state),
    do: {:reply, {:ok, :stop_requested}, pend_safe_stop(state)}

  def handle_call(:status, _from, state) do
    {:reply,
     {:ok,
      %{
        status: state.status,
        session_id: state.session_id,
        open_tool_count: map_size(state.tool_kinds),
        stop_requested: state.stop_requested,
        event_count: length(state.buffered_events),
        malformed_lines: state.malformed_lines
      }}, state}
  end

  def handle_call(:shutdown, _from, state) do
    reap(state)
    close_transport(state)
    {:stop, :normal, :ok, state}
  end

  # --- Transport ---

  @impl GenServer
  def handle_info({:codex_transport_connected, _pid}, state) do
    timeout = Keyword.get(state.opts, :handshake_timeout_ms, @default_handshake_timeout_ms)
    state = %{state | handshake_timer: Process.send_after(self(), :handshake_timeout, timeout)}

    {:noreply,
     request(
       state,
       "initialize",
       %{
         "protocolVersion" => @protocol_version,
         "clientCapabilities" => %{
           "fs" => %{"readTextFile" => false, "writeTextFile" => false},
           "terminal" => false
         },
         "clientInfo" => %{"name" => "shoestring", "version" => "1"}
       },
       :initialize
     )}
  end

  def handle_info(:handshake_timeout, %{prompt_id: nil, status: :starting} = state) do
    state =
      fail(
        state,
        Error.new(:transport, "handshake_timeout", "opencode did not finish the handshake")
      )

    reap(state)
    {:noreply, state}
  end

  def handle_info(:handshake_timeout, state), do: {:noreply, state}

  def handle_info({:codex_transport_frame, _pid, line}, state) do
    if terminal?(state.status) do
      {:noreply, state}
    else
      case Jason.decode(line) do
        {:ok, frame} when is_map(frame) ->
          # A frame that fails to handle must never take the session down
          # and lose the live buffer (no backfill exists).
          state =
            try do
              frame(frame, state)
            rescue
              error ->
                Logger.warning(
                  "OpencodeAcp frame handling raised: #{inspect(error)}; skipping frame"
                )

                %{state | malformed_lines: state.malformed_lines + 1}
            end

          {:noreply, state}

        _other ->
          {:noreply, %{state | malformed_lines: state.malformed_lines + 1}}
      end
    end
  end

  def handle_info({:codex_transport_error, _pid, :oversized_frame}, state) do
    state = send_cancel(state)
    reap(state)

    {:noreply,
     fail(state, Error.new(:transport, "oversized_frame", "Line cap exceeded; output refused"))}
  end

  def handle_info({:codex_transport_closed, _pid, reason}, state),
    do: {:noreply, transport_gone(state, reason)}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{transport_ref: ref} = state),
    do: {:noreply, transport_gone(state, reason)}

  def handle_info(_other, state), do: {:noreply, state}

  # --- Protocol ---

  # Agent → client request (it carries both an id and a method).
  defp frame(%{"id" => id, "method" => method} = frame, state) when not is_nil(id) do
    case method do
      "session/request_permission" -> permission(id, frame["params"] || %{}, state)
      _ -> reply(state, id, nil, %{"code" => -32601, "message" => "Method not supported"})
    end
  end

  defp frame(%{"id" => id} = response, state) when not is_nil(id) do
    case Map.pop(state.pending_requests, id) do
      {nil, _} -> state
      {tag, pending} -> response(tag, response, %{state | pending_requests: pending})
    end
  end

  defp frame(%{"method" => "session/update"} = frame, state), do: session_update(frame, state)
  defp frame(_other, state), do: state

  defp response(:prompt, response, state) do
    outcome =
      if response["error"],
        do: {:error, response["error"]},
        else: {:ok, response["result"] || %{}}

    state = flush_message(state)

    state =
      buffer(state, &EventNormalizer.prompt_outcome(outcome, state.run_id, &1, event_opts(state)))

    status =
      case outcome do
        {:ok, %{"stopReason" => "end_turn"}} -> :completed
        {:ok, %{"stopReason" => "cancelled"}} -> :interrupted
        _ -> :failed
      end

    # A single-prompt session is over: reap unless the supervising Elf owns
    # the process group (it reaps after recording the verdict).
    unless state.elf_owned_process_group, do: reap(state)
    %{state | status: status, stop_requested: nil, tool_kinds: %{}}
  end

  defp response(tag, %{"error" => error}, state) do
    message = if is_map(error), do: error["message"], else: nil

    err =
      Error.new(
        if(tag == :model, do: :schema_incompatible, else: :transport),
        "rpc_error",
        "#{tag} failed: #{EventNormalizer.sanitize_string(message || inspect(error))}"
      )

    reap(state)
    fail(state, err)
  end

  defp response(:initialize, %{"result" => result}, state) do
    if result["protocolVersion"] == @protocol_version do
      if state.session_id && Keyword.get(state.opts, :resume, false) do
        request(
          state,
          "session/resume",
          %{"sessionId" => state.session_id, "cwd" => cwd(state), "mcpServers" => []},
          :session
        )
      else
        request(state, "session/new", %{"cwd" => cwd(state), "mcpServers" => []}, :session)
      end
    else
      reap(state)

      fail(
        state,
        Error.new(
          :schema_incompatible,
          "protocol_version",
          "opencode speaks ACP version #{inspect(result["protocolVersion"])}"
        )
      )
    end
  end

  defp response(:session, %{"result" => result}, state) do
    state = %{state | session_id: result["sessionId"] || state.session_id}
    configure(state, result["configOptions"] || [])
  end

  defp response(:model, %{"result" => result}, state),
    do: effort(state, result["configOptions"] || [])

  defp response(:effort, _response, state), do: prompt(state)
  defp response(_tag, _response, state), do: state

  # The model is required: a run never falls back to opencode's own default.
  defp configure(state, _options) do
    case Keyword.get(state.opts, :model) do
      model when is_binary(model) and model != "" ->
        request(
          state,
          "session/set_config_option",
          %{"sessionId" => state.session_id, "configId" => "model", "value" => model},
          :model
        )

      _ ->
        reap(state)

        fail(
          state,
          Error.new(
            :schema_incompatible,
            "model_required",
            "An opencode run needs an explicit model"
          )
        )
    end
  end

  # Effort values are per model (read from the session after the model is
  # set); one the model does not offer refuses the run instead of guessing.
  defp effort(state, options) do
    case Keyword.get(state.opts, :effort) do
      effort when is_binary(effort) and effort != "" ->
        offered =
          options
          |> Enum.find(%{}, &(&1["id"] == "effort"))
          |> Map.get("options", [])
          |> Enum.map(& &1["value"])

        if effort in offered do
          request(
            state,
            "session/set_config_option",
            %{"sessionId" => state.session_id, "configId" => "effort", "value" => effort},
            :effort
          )
        else
          reap(state)

          fail(
            state,
            Error.new(
              :unsupported_capability,
              "effort_not_offered",
              "The model does not offer effort #{effort}"
            )
          )
        end

      _ ->
        prompt(state)
    end
  end

  defp prompt(state) do
    text =
      if Keyword.get(state.opts, :resume, false),
        do: Continuation.resume_prompt(state.run_request),
        else: (state.run_request && state.run_request.prompt) || "Execute task."

    state =
      request(
        state,
        "session/prompt",
        %{"sessionId" => state.session_id, "prompt" => [%{"type" => "text", "text" => text}]},
        :prompt
      )

    cancel_timer(state)

    state = %{
      state
      | prompt_id: state.next_request_id - 1,
        status: :turn_in_progress,
        handshake_timer: nil
    }

    reply_waiters(state, run_identity(state))
  end

  defp session_update(%{"params" => %{"update" => update}} = frame, state) when is_map(update) do
    state =
      case update["sessionUpdate"] do
        "agent_message_chunk" ->
          text = get_in(update, ["content", "text"])
          if is_binary(text), do: %{state | message: (state.message || "") <> text}, else: state

        "tool_call" ->
          state = flush_message(state)
          %{state | tool_kinds: Map.put(state.tool_kinds, update["toolCallId"], update["kind"])}

        _ ->
          state
      end

    state =
      buffer(state, fn ordinal ->
        EventNormalizer.normalize(
          frame,
          state.run_id,
          ordinal,
          Map.put(event_opts(state), :tool_kinds, state.tool_kinds)
        )
      end)

    if update["sessionUpdate"] == "tool_call_update" and
         update["status"] in ["completed", "failed"],
       do: %{state | tool_kinds: Map.delete(state.tool_kinds, update["toolCallId"])},
       else: state
  end

  defp session_update(_frame, state), do: %{state | malformed_lines: state.malformed_lines + 1}

  defp flush_message(%{message: text} = state) when is_binary(text) and text != "" do
    state =
      buffer(state, &EventNormalizer.message_completed(text, state.run_id, &1, event_opts(state)))

    %{state | message: nil}
  end

  defp flush_message(state), do: %{state | message: nil}

  # Fixed policy: the OS sandbox decides what a sandboxed run may touch; an
  # unsandboxed run is never granted anything.
  defp permission(id, params, state) do
    options = params["options"] || []

    kinds =
      if Keyword.get(state.opts, :sandboxed, false),
        do: ["allow_once"],
        else: ["reject_once", "reject_always"]

    outcome =
      case Enum.find(options, &(&1["kind"] in kinds)) do
        %{"optionId" => option} -> %{"outcome" => "selected", "optionId" => option}
        _ -> %{"outcome" => "cancelled"}
      end

    granted = outcome["outcome"] == "selected" and Keyword.get(state.opts, :sandboxed, false)

    state =
      buffer(state, fn ordinal ->
        HarnessEvent.new(%{
          version: 1,
          run_id: state.run_id,
          source_event_id: "permission-#{ordinal}",
          ordinal: ordinal,
          occurred_at: DateTime.utc_now(),
          kind: :lifecycle,
          process_id: event_opts(state).process_id,
          provider_session_id: state.session_id,
          artifact_id: nil,
          capacity_snapshot_id: nil,
          error: nil,
          result: nil,
          extensions: %{
            "opencode-acp:permission" => if(granted, do: "allowed_once", else: "refused"),
            "opencode-acp:tool_kind" => get_in(params, ["toolCall", "kind"])
          }
        })
      end)

    reply(state, id, %{"outcome" => outcome}, nil)
  end

  # --- Stop and cancel ---

  defp pend_safe_stop(state) do
    if terminal?(state.status), do: state, else: %{state | stop_requested: :safe_boundary}
  end

  defp cancel_now(state) do
    if terminal?(state.status) do
      state
    else
      state = send_cancel(state)
      reap(state)
      %{state | cancel_requested: true, stop_requested: nil}
    end
  end

  defp send_cancel(%{session_id: id, transport_pid: pid} = state)
       when is_binary(id) and is_pid(pid) do
    _ =
      state.transport_mod.send_frame(pid, %{
        "jsonrpc" => "2.0",
        "method" => "session/cancel",
        "params" => %{"sessionId" => id}
      })

    state
  catch
    :exit, _ -> state
  end

  defp send_cancel(state), do: state

  # The transport closing before the prompt outcome: an explicit cancel
  # becomes the interrupted outcome; anything else is a transport failure.
  defp transport_gone(state, reason) do
    cancel_timer(state)
    state = %{state | transport_pid: nil, transport_ref: nil}

    cond do
      terminal?(state.status) ->
        state

      state.cancel_requested ->
        state = flush_message(state)

        state =
          buffer(
            state,
            &EventNormalizer.prompt_outcome(
              {:ok, %{"stopReason" => "cancelled"}},
              state.run_id,
              &1,
              event_opts(state)
            )
          )

        %{state | status: :interrupted, tool_kinds: %{}}

      true ->
        reap(state)
        fail(state, Error.new(:transport, "transport_closed", inspect(reason)))
    end
  end

  defp reap(%{transport_os_pid: pid}) when is_integer(pid), do: ProcessTree.reap(pid)
  defp reap(_state), do: []

  defp close_transport(state) do
    if is_nil(Keyword.get(state.opts, :transport_pid)) and is_pid(state.transport_pid) and
         Process.alive?(state.transport_pid) do
      state.transport_mod.close(state.transport_pid)
    end

    :ok
  catch
    _, _ -> :ok
  end

  # --- Helpers ---

  defp fail(state, %Error{} = error) do
    cancel_timer(state)
    state = flush_message(state)

    state =
      buffer(state, fn ordinal ->
        HarnessEvent.new(%{
          version: 1,
          run_id: state.run_id,
          source_event_id: "synthetic-error-#{ordinal}",
          ordinal: ordinal,
          occurred_at: DateTime.utc_now(),
          kind: :error,
          process_id: event_opts(state).process_id,
          provider_session_id: state.session_id,
          artifact_id: nil,
          capacity_snapshot_id: nil,
          error: error,
          result: nil,
          extensions: %{"opencode-acp:synthetic" => true}
        })
      end)

    state = %{state | status: :failed, terminal_result: {:error, error}, handshake_timer: nil}
    reply_waiters(state, {:error, error})
  end

  defp buffer(state, build) do
    ordinal = state.event_ordinal + 1

    case build.(ordinal) do
      {:ok, %HarnessEvent{} = event} ->
        %{state | buffered_events: [event | state.buffered_events], event_ordinal: ordinal}

      {:skip, _reason} ->
        state

      {:error, reason} ->
        Logger.warning("OpencodeAcp event normalization error: #{inspect(reason)}")
        %{state | malformed_lines: state.malformed_lines + 1}
    end
  end

  defp event_opts(state) do
    %{
      process_id: state.transport_os_pid && to_string(state.transport_os_pid),
      provider_session_id: state.session_id
    }
  end

  defp request(state, method, params, tag) do
    id = state.next_request_id
    send_frame(state, %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
    %{state | next_request_id: id + 1, pending_requests: Map.put(state.pending_requests, id, tag)}
  end

  defp reply(state, id, result, error) do
    frame =
      if error,
        do: %{"jsonrpc" => "2.0", "id" => id, "error" => error},
        else: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

    send_frame(state, frame)
    state
  end

  defp send_frame(%{transport_pid: pid} = state, frame) when is_pid(pid) do
    state.transport_mod.send_frame(pid, frame)
  catch
    :exit, _ -> :ok
  end

  defp send_frame(_state, _frame), do: :ok

  defp run_identity(state) do
    RunIdentity.new(%{
      run_id: state.run_id,
      harness_id: "opencode_acp",
      process_id:
        (state.transport_os_pid && to_string(state.transport_os_pid)) ||
          "os-pid-#{System.unique_integer([:positive])}",
      provider_session_id: state.session_id || "session-#{state.run_id}"
    })
  end

  defp reply_waiters(state, result) do
    Enum.each(state.identity_waiters, &GenServer.reply(&1, result))
    %{state | identity_waiters: []}
  end

  defp cwd(state),
    do:
      Keyword.get(state.opts, :workdir) || (state.run_request && state.run_request.workspace_ref)

  defp os_pid(state, pid) do
    if function_exported?(state.transport_mod, :os_pid, 1), do: state.transport_mod.os_pid(pid)
  end

  defp cancel_timer(%{handshake_timer: ref}) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel_timer(_state), do: :ok

  defp terminal?(status), do: status in [:completed, :interrupted, :failed]
end
