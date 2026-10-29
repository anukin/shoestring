defmodule Shoestring.Harness.OpencodeAcp.Conversation do
  @moduledoc """
  Read-only ACP coordinator using direct MCP tools and no Code Mode.

  Requires opencode 2.0.31+ and the named Shoestring agent to be offered before
  any prompt. Its private configuration allows only local reading/search and
  Shoestring tools. `execute` is denied; MCP's `codemode: false` keeps the tools
  available without JavaScript fetch. Project/user agent configuration is not
  loaded. Model and effort selection failures refuse instead of falling back.
  Protocol and policy are tested with a scripted local transport; a live
  subscription session is separately budgeted evidence.
  """
  use GenServer
  @behaviour Shoestring.Harness.Conversation
  alias Shoestring.Harness.{Conversation, ConversationEvent, Error}
  alias Shoestring.Harness.Capacity.Codex.StdioTransport
  alias Shoestring.Harness.OpencodeAcp.ProcessTree
  @exit_wait_ms 2_000
  @agent "shoestring-coordinator"
  @impl Conversation
  def start_link(spec, opts \\ []) do
    with :ok <- Conversation.validate(spec) do
      GenServer.start_link(__MODULE__, {spec, opts})
    end
  end

  @impl Conversation
  def send_turn(pid, turn_id, text) when is_binary(turn_id) and is_binary(text) do
    GenServer.call(pid, {:turn, turn_id, text})
  catch
    :exit, _ -> {:error, Conversation.closed()}
  end

  @impl Conversation
  def cancel_turn(pid) do
    GenServer.call(pid, :cancel_turn)
  catch
    :exit, _ -> :ok
  end

  @impl Conversation
  def close(pid) do
    GenServer.call(pid, :close, @exit_wait_ms + 10_000)
  catch
    :exit, _ -> :ok
  end

  @impl Conversation
  def status(pid) do
    GenServer.call(pid, :status)
  catch
    :exit, _ -> %{state: :closed, turn_id: nil, provider_session_id: nil}
  end

  @doc "Private V2 configuration. Direct MCP survives an explicit Code Mode denial."
  def config(spec) do
    permissions =
      [%{action: "*", resource: "*", effect: "deny"}] ++
        Enum.map(~w(read glob grep shoestring_*), &%{action: &1, resource: "*", effect: "allow"}) ++
        [%{action: "execute", resource: "*", effect: "deny"}]

    servers =
      case spec[:tools] do
        %{url: url} ->
          %{
            shoestring: %{
              type: "remote",
              url: url,
              oauth: false,
              codemode: false,
              headers: %{Authorization: "Bearer {env:SHOESTRING_CHAT_TOOL_TOKEN}"}
            }
          }

        _ ->
          %{}
      end

    %{
      default_agent: @agent,
      permissions: permissions,
      agents: %{
        @agent => %{
          mode: "primary",
          permissions: permissions,
          system:
            "You coordinate read-only. Delegate every change through Shoestring.\n" <>
              (spec[:instructions] || "")
        }
      },
      mcp: %{servers: servers},
      plugins: []
    }
  end

  @impl true
  def init({spec, opts}) do
    Process.flag(:trap_exit, true)

    with {:ok, dir} <- Shoestring.SandboxTemp.create("shoestring-opencode-chat") do
      File.chmod!(dir, 0o700)

      state = %{
        owner: spec.owner,
        spec: spec,
        dir: dir,
        transport: nil,
        os_pid: nil,
        ordinal: 0,
        turn: nil,
        turn_request: nil,
        request: 10,
        session: nil,
        state: :starting,
        interrupting: false,
        tools: %{},
        exit_wait_ms: Keyword.get(opts, :exit_wait_ms, @exit_wait_ms)
      }

      case launch(state, opts) do
        {:ok, state} ->
          Process.monitor(spec.owner)
          {:ok, emit(%{state | state: :idle}, :session, provider_session_id: state.session)}

        {:error, error, state} ->
          cleanup(state)
          {:error, error}
      end
    else
      _ -> {:error, failure("private_config_unavailable")}
    end
  end

  defp launch(state, opts) do
    executable = Keyword.get(opts, :executable) || System.find_executable("opencode")

    env = [
      {"XDG_CONFIG_HOME", state.dir},
      {"OPENCODE_CONFIG_DIR", state.dir},
      {"OPENCODE_CONFIG", false},
      {"OPENCODE_CONFIG_CONTENT", Jason.encode!(config(state.spec))},
      {"OPENCODE_CONFIG_PROJECT_DISABLE", "1"},
      {"OPENCODE_DISABLE_CLAUDE_CODE", "1"},
      {"OPENCODE_DISABLE_AUTOUPDATE", "1"},
      {"OPENCODE_DISABLE_MODELS_FETCH", "1"},
      {"OPENCODE_PERMISSION", false},
      {"OPENAI_API_KEY", false},
      {"ANTHROPIC_API_KEY", false},
      {"SHOESTRING_CHAT_TOOL_TOKEN", get_in(state.spec, [:tools, :token]) || false}
    ]

    env =
      Enum.reduce(Keyword.get(opts, :env, []), env, fn {k, v}, acc ->
        List.keystore(acc, k, 0, {k, v})
      end)

    if executable do
      case StdioTransport.start_link(
             owner: self(),
             executable: executable,
             args: ["acp"],
             cd: state.spec.workdir,
             env: env
           ) do
        {:ok, transport} ->
          state = %{state | transport: transport, os_pid: StdioTransport.os_pid(transport)}

          case handshake(state, Keyword.get(opts, :handshake_timeout_ms, 15_000)) do
            {:ok, state} -> {:ok, state}
            {:error, error} -> {:error, error, state}
          end

        _ ->
          {:error, failure("start_failed"), state}
      end
    else
      {:error, failure("binary_missing"), state}
    end
  end

  defp handshake(state, timeout) do
    with {:ok, init} <-
           rpc(
             state,
             1,
             "initialize",
             %{
               protocolVersion: 1,
               clientCapabilities: %{
                 fs: %{readTextFile: false, writeTextFile: false},
                 terminal: false
               },
               clientInfo: %{name: "shoestring", version: "0.2.0"}
             },
             timeout
           ),
         :ok <- compatible(init),
         {:ok, result} <- session(state, timeout),
         id when is_binary(id) <- result["sessionId"] || state.spec[:resume],
         true <- is_nil(state.spec[:resume]) or id == state.spec.resume,
         :ok <- agent_offered(result),
         state = %{state | session: id},
         :ok <- select_agent(state, timeout),
         {:ok, selected} <- select_model(state, timeout),
         :ok <- agent_current(selected),
         :ok <- effort(state, selected, timeout) do
      {:ok, state}
    else
      {:error, error} -> {:error, error}
      _ -> {:error, failure("session_refused")}
    end
  end

  defp compatible(%{"protocolVersion" => 1, "agentInfo" => %{"version" => version}}) do
    case Version.parse(version) do
      {:ok, version} ->
        if Version.compare(version, "2.0.31") in [:eq, :gt],
          do: :ok,
          else: {:error, failure("direct_tools_not_supported")}

      _ ->
        {:error, failure("direct_tools_not_supported")}
    end
  end

  defp compatible(_), do: {:error, failure("direct_tools_not_supported")}

  defp session(state, timeout) do
    params = %{cwd: state.spec.workdir, mcpServers: []}

    {method, params} =
      if state.spec[:resume],
        do: {"session/resume", Map.put(params, :sessionId, state.spec.resume)},
        else: {"session/new", params}

    rpc(state, 2, method, params, timeout)
  end

  # opencode 2.0.31 offers its agents as the session's `mode` config option
  # (`modes` is null), so the agent is chosen and confirmed like the model.
  defp agent_offered(result) do
    mode = option(result, "mode")

    if mode && Enum.any?(mode["options"] || [], &(&1["value"] == @agent)),
      do: :ok,
      else: {:error, failure("readonly_agent_not_offered")}
  end

  defp select_agent(state, timeout) do
    case rpc(
           state,
           3,
           "session/set_config_option",
           %{sessionId: state.session, configId: "mode", value: @agent},
           timeout
         ) do
      {:ok, result} -> agent_current(result)
      _ -> {:error, failure("readonly_agent_not_offered")}
    end
  end

  defp agent_current(result) do
    if option(result, "mode")["currentValue"] == @agent,
      do: :ok,
      else: {:error, failure("readonly_agent_not_offered")}
  end

  defp option(result, id), do: Enum.find(result["configOptions"] || [], &(&1["id"] == id))

  defp select_model(state, timeout) do
    case rpc(
           state,
           4,
           "session/set_config_option",
           %{sessionId: state.session, configId: "model", value: state.spec.model},
           timeout
         ) do
      {:ok, result} ->
        model = option(result, "model")

        if model && model["currentValue"] == state.spec.model,
          do: {:ok, result},
          else:
            {:error,
             Error.new(
               :schema_incompatible,
               "model_not_offered",
               "opencode did not select the requested model"
             )}

      _ ->
        {:error,
         Error.new(
           :schema_incompatible,
           "model_not_offered",
           "opencode refused the requested model"
         )}
    end
  end

  defp effort(state, result, timeout) do
    case state.spec[:effort] do
      nil ->
        :ok

      effort ->
        offered = option(result, "effort")

        if offered && Enum.any?(offered["options"] || [], &(&1["value"] == effort)) do
          case rpc(
                 state,
                 5,
                 "session/set_config_option",
                 %{sessionId: state.session, configId: "effort", value: effort},
                 timeout
               ) do
            {:ok, selected} ->
              if Enum.any?(
                   selected["configOptions"] || [],
                   &(&1["id"] == "effort" and &1["currentValue"] == effort)
                 ), do: :ok, else: {:error, failure("effort_not_offered")}

            error ->
              error
          end
        else
          {:error, failure("effort_not_offered")}
        end
    end
  end

  defp rpc(state, id, method, params, timeout) do
    case StdioTransport.send_frame(state.transport, %{
           jsonrpc: "2.0",
           id: id,
           method: method,
           params: params
         }) do
      :ok -> await_rpc(state.transport, id, System.monotonic_time(:millisecond) + timeout)
      _ -> {:error, failure("send_failed")}
    end
  end

  defp await_rpc(transport, id, deadline) do
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:codex_transport_frame, ^transport, line} ->
        case Jason.decode(line) do
          {:ok, %{"id" => ^id, "result" => result}} ->
            {:ok, result}

          {:ok, %{"id" => ^id, "error" => _}} ->
            {:error, failure("request_refused")}

          {:ok, %{"id" => request, "method" => _}} ->
            refuse(transport, request)
            await_rpc(transport, id, deadline)

          _ ->
            await_rpc(transport, id, deadline)
        end

      {:codex_transport_error, ^transport, _} ->
        {:error, failure("oversized_frame")}

      {:codex_transport_closed, ^transport, _} ->
        {:error, failure("transport_closed")}
    after
      wait -> {:error, failure("handshake_timeout")}
    end
  end

  @impl true
  def handle_call({:turn, _, _}, _, %{turn: turn} = state) when not is_nil(turn),
    do: {:reply, {:error, Conversation.turn_in_progress(turn)}, state}

  def handle_call({:turn, turn, text}, _, state) do
    case StdioTransport.send_frame(state.transport, %{
           jsonrpc: "2.0",
           id: state.request,
           method: "session/prompt",
           params: %{sessionId: state.session, prompt: [%{type: "text", text: text}]}
         }) do
      :ok ->
        state = %{
          state
          | turn: turn,
            turn_request: state.request,
            request: state.request + 1,
            state: :in_turn,
            interrupting: false,
            tools: %{}
        }

        {:reply, :ok, emit(state, :turn_started, turn_id: turn)}

      _ ->
        {:reply, {:error, failure("send_failed")}, state}
    end
  end

  def handle_call(:cancel_turn, _, %{turn: nil} = state), do: {:reply, :ok, state}

  def handle_call(:cancel_turn, _, state) do
    _ =
      StdioTransport.send_frame(state.transport, %{
        jsonrpc: "2.0",
        method: "session/cancel",
        params: %{sessionId: state.session}
      })

    {:reply, :ok, %{state | interrupting: true}}
  end

  def handle_call(:close, _, state), do: {:stop, :normal, :ok, shutdown(state, :normal)}

  def handle_call(:status, _, state),
    do:
      {:reply, %{state: state.state, turn_id: state.turn, provider_session_id: state.session},
       state}

  @impl true
  def handle_info({:codex_transport_frame, transport, line}, %{transport: transport} = state) do
    case Jason.decode(line) do
      {:ok, frame} -> {:noreply, frame(state, frame)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:codex_transport_closed, transport, reason}, %{transport: transport} = state),
    do: {:stop, :normal, shutdown(%{state | transport: nil}, reason)}

  def handle_info({:codex_transport_error, transport, reason}, %{transport: transport} = state),
    do: {:stop, :normal, shutdown(state, reason)}

  def handle_info({:DOWN, _, :process, owner, _}, %{owner: owner} = state),
    do: {:stop, :normal, shutdown(state, :owner_down)}

  def handle_info(_, state), do: {:noreply, state}
  @impl true
  def terminate(_, state) do
    if state.state != :closed, do: cleanup(state)
    :ok
  end

  defp frame(state, %{"id" => id, "method" => "session/request_permission"}) do
    _ =
      StdioTransport.send_frame(state.transport, %{
        jsonrpc: "2.0",
        id: id,
        result: %{outcome: %{outcome: "cancelled"}}
      })

    state
  end

  defp frame(state, %{"id" => id, "method" => _}) do
    refuse(state.transport, id)
    state
  end

  defp frame(%{turn: nil} = state, _), do: state

  defp frame(state, %{"id" => id} = frame) when id == state.turn_request do
    status =
      case get_in(frame, ["result", "stopReason"]) do
        "end_turn" -> :completed
        "cancelled" -> :interrupted
        _ -> :failed
      end

    state = emit(state, :turn_completed, turn_id: state.turn, status: status)
    %{state | turn: nil, turn_request: nil, state: :idle, interrupting: false, tools: %{}}
  end

  defp frame(state, %{
         "method" => "session/update",
         "params" => %{"sessionId" => session, "update" => update}
       })
       when session == state.session do
    case update do
      %{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => text}
      } ->
        emit(state, :text, turn_id: state.turn, text: text)

      %{"sessionUpdate" => "tool_call", "toolCallId" => id, "title" => name} ->
        emit(%{state | tools: Map.put(state.tools, id, name)}, :tool_call,
          turn_id: state.turn,
          tool: name,
          tool_call_id: id
        )

      %{"sessionUpdate" => "tool_call_update", "toolCallId" => id, "status" => status}
      when status in ["completed", "failed"] ->
        emit(state, :tool_result,
          turn_id: state.turn,
          tool_call_id: id,
          is_error: status == "failed"
        )

      _ ->
        state
    end
  end

  defp frame(state, _), do: state

  defp refuse(transport, id),
    do:
      StdioTransport.send_frame(transport, %{
        jsonrpc: "2.0",
        id: id,
        error: %{code: -32601, message: "Coordinator requests are refused"}
      })

  defp failure(code), do: Error.new(:transport, code, "opencode conversation " <> code)

  defp emit(state, type, fields) do
    ordinal = state.ordinal + 1

    Kernel.send(
      state.owner,
      {:conversation_event, self(), ConversationEvent.new(type, ordinal, fields)}
    )

    %{state | ordinal: ordinal}
  end

  defp shutdown(state, reason) do
    state = cleanup(state)
    emit(%{state | state: :closed}, :closed, reason: reason, turn_id: state.turn)
  end

  defp cleanup(state) do
    groups = if state.os_pid, do: ProcessTree.groups(state.os_pid), else: []
    if state.transport, do: StdioTransport.close(state.transport)

    if groups != [] do
      wait_gone(groups, System.monotonic_time(:millisecond) + state.exit_wait_ms)
      _ = ProcessTree.reap(state.os_pid, known: groups)
    end

    _ = Shoestring.SandboxTemp.remove(state.dir, "shoestring-opencode-chat")
    %{state | transport: nil, state: :closed}
  end

  defp wait_gone(groups, deadline) do
    if Enum.any?(groups, &ProcessTree.alive?/1) and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(50)
      wait_gone(groups, deadline)
    end
  end
end
