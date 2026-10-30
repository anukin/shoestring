defmodule Shoestring.Harness.CodexAppServer.Conversation do
  @moduledoc """
  Read-only Codex coordinator over app-server stdio. One thread, one turn at a time.
  Model selection is checked against model/list (a catalog, not entitlement).
  Read-only sandbox and never-approve are applied on both start and resume and
  every turn. Visible deltas and MCP tool names are forwarded; reasoning and tool
  arguments are ignored. No call is retried after delivery.
  """
  use GenServer
  @behaviour Shoestring.Harness.Conversation
  alias Shoestring.Harness.{Conversation, ConversationEvent, Error}
  alias Shoestring.Harness.Capacity.Codex.StdioTransport
  alias Shoestring.Harness.OpencodeAcp.ProcessTree
  @exit_wait_ms 2_000
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

  @doc "Launch arguments. The bearer token is supplied through the environment only."
  def argv(spec) do
    servers =
      case spec[:tools] do
        %{url: url} ->
          %{
            shoestring: %{
              url: url,
              bearer_token_env_var: "SHOESTRING_CHAT_TOOL_TOKEN",
              default_tools_approval_mode: "approve"
            }
          }

        _ ->
          %{}
      end

    disabled = ~w(apps plugins remote_plugin computer_use browser_use code_mode
      code_mode_host multi_agent multi_agent_v2 memories hooks workspace_dependencies goals
      sleep_tool view_image image_generation tool_suggest request_permissions_tool
      unbounded_connection_retries)

    config =
      [
        "mcp_servers=" <> toml(servers),
        ~s(web_search="disabled"),
        "agents.enabled=false",
        "project_doc_max_bytes=0",
        ~s(model_reasoning_summary="none"),
        "analytics.enabled=false",
        "check_for_update_on_startup=false"
      ] ++
        Enum.map(disabled, &("features." <> &1 <> "=false"))

    Enum.flat_map(config, &["-c", &1]) ++ ["app-server"]
  end

  defp toml(map) when is_map(map),
    do: "{" <> Enum.map_join(map, ", ", fn {k, v} -> "#{k} = #{toml(v)}" end) <> "}"

  defp toml(value), do: Jason.encode!(value)

  @impl true
  def init({spec, opts}) do
    Process.flag(:trap_exit, true)

    state = %{
      owner: spec.owner,
      spec: spec,
      transport: nil,
      os_pid: nil,
      ordinal: 0,
      turn: nil,
      provider_turn: nil,
      session: nil,
      state: :starting,
      interrupting: false,
      request: 10,
      turn_request: nil,
      seen_text: MapSet.new(),
      exit_wait_ms: Keyword.get(opts, :exit_wait_ms, @exit_wait_ms)
    }

    executable = Keyword.get(opts, :executable) || System.find_executable("codex")

    env = [
      {"OPENAI_API_KEY", false},
      {"CODEX_API_KEY", false},
      {"SHOESTRING_CHAT_TOOL_TOKEN", get_in(spec, [:tools, :token]) || false}
    ]

    env =
      Enum.reduce(Keyword.get(opts, :env, []), env, fn {k, v}, acc ->
        List.keystore(acc, k, 0, {k, v})
      end)

    if executable do
      case StdioTransport.start_link(
             owner: self(),
             executable: executable,
             args: argv(spec),
             cd: spec.workdir,
             env: env
           ) do
        {:ok, transport} ->
          state = %{state | transport: transport, os_pid: StdioTransport.os_pid(transport)}

          case handshake(state, Keyword.get(opts, :handshake_timeout_ms, 15_000)) do
            {:ok, state} ->
              Process.monitor(spec.owner)
              {:ok, emit(%{state | state: :idle}, :session, provider_session_id: state.session)}

            {:error, error} ->
              cleanup(state)
              {:error, error}
          end

        {:error, _} ->
          {:error, failure("start_failed")}
      end
    else
      {:error, failure("binary_missing")}
    end
  end

  defp handshake(state, timeout) do
    with {:ok, _} <-
           rpc(
             state,
             1,
             "initialize",
             %{clientInfo: %{name: "shoestring", version: "0.2.0"}},
             timeout
           ),
         :ok <- StdioTransport.send_frame(state.transport, %{method: "initialized", params: %{}}),
         :ok <- offered(state, nil, timeout) do
      spec = state.spec

      params = %{
        cwd: spec.workdir,
        model: spec.model,
        approvalPolicy: "never",
        sandbox: "read-only",
        developerInstructions: spec[:instructions]
      }

      {method, params} =
        if spec[:resume],
          do: {"thread/resume", Map.put(params, :threadId, spec.resume)},
          else: {"thread/start", params}

      with {:ok, result} <- rpc(state, 3, method, params, timeout),
           id when is_binary(id) <- get_in(result, ["thread", "id"]),
           true <- is_nil(spec[:resume]) or id == spec.resume do
        {:ok, %{state | session: id}}
      else
        _ -> {:error, failure("thread_refused")}
      end
    end
  end

  defp offered(state, cursor, timeout) do
    with {:ok, result} <- rpc(state, 2, "model/list", %{limit: 100, cursor: cursor}, timeout) do
      case Enum.find(result["data"] || [], &(state.spec.model in [&1["model"], &1["id"]])) do
        nil ->
          if result["nextCursor"],
            do: offered(state, result["nextCursor"], timeout),
            else:
              {:error,
               Error.new(
                 :schema_incompatible,
                 "model_not_offered",
                 "Codex does not list the selected model"
               )}

        model ->
          if is_nil(state.spec[:effort]) or
               Enum.any?(
                 model["supportedReasoningEfforts"] || [],
                 &(&1["reasoningEffort"] == state.spec.effort)
               ),
             do: :ok,
             else:
               {:error,
                Error.new(
                  :schema_incompatible,
                  "effort_not_offered",
                  "Codex does not list the selected effort"
                )}
      end
    end
  end

  defp rpc(state, id, method, params, timeout) do
    case StdioTransport.send_frame(state.transport, %{id: id, method: method, params: params}) do
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
    params = %{
      threadId: state.session,
      input: [%{type: "text", text: text}],
      model: state.spec.model,
      effort: state.spec[:effort],
      approvalPolicy: "never",
      sandboxPolicy: %{type: "readOnly"}
    }

    case StdioTransport.send_frame(state.transport, %{
           id: state.request,
           method: "turn/start",
           params: params
         }) do
      :ok ->
        state = %{
          state
          | turn: turn,
            turn_request: state.request,
            request: state.request + 1,
            provider_turn: nil,
            state: :in_turn,
            interrupting: false,
            seen_text: MapSet.new()
        }

        {:reply, :ok, emit(state, :turn_started, turn_id: turn)}

      _ ->
        {:reply, {:error, failure("send_failed")}, state}
    end
  end

  def handle_call(:cancel_turn, _, state) do
    {:reply, :ok, interrupt(%{state | interrupting: not is_nil(state.turn)})}
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

  defp frame(state, %{"id" => id, "method" => _}) do
    refuse(state.transport, id)
    state
  end

  defp frame(%{turn: nil} = state, _), do: state

  defp frame(state, %{"id" => id, "error" => _}) when id == state.turn_request,
    do: complete(state, :failed)

  defp frame(state, %{"id" => id, "result" => %{"turn" => %{"id" => turn}}})
       when id == state.turn_request,
       do: interrupt(%{state | provider_turn: turn})

  defp frame(state, %{"method" => method, "params" => %{"threadId" => thread} = params})
       when thread == state.session do
    case method do
      "turn/started" ->
        interrupt(%{state | provider_turn: params["turn"]["id"]})

      "item/agentMessage/delta" ->
        if params["turnId"] == state.provider_turn do
          emit(%{state | seen_text: MapSet.put(state.seen_text, params["itemId"])}, :text,
            turn_id: state.turn,
            text_item: params["itemId"],
            text: params["delta"] || ""
          )
        else
          state
        end

      "item/started" ->
        tool(state, params, :tool_call)

      "item/completed" ->
        item = params["item"] || %{}

        cond do
          params["turnId"] != state.provider_turn ->
            state

          item["type"] == "agentMessage" ->
            text =
              if MapSet.member?(state.seen_text, item["id"]), do: "", else: item["text"] || ""

            emit(state, :text,
              turn_id: state.turn,
              text: text,
              text_item: item["id"],
              text_complete: true
            )

          true ->
            tool(state, params, :tool_result)
        end

      "turn/completed" ->
        turn = params["turn"] || %{}

        if turn["id"] == state.provider_turn do
          status =
            case turn["status"] do
              "completed" -> :completed
              "interrupted" -> :interrupted
              _ -> :failed
            end

          complete(state, status)
        else
          state
        end

      _ ->
        state
    end
  end

  defp frame(state, _), do: state

  defp tool(state, params, type) do
    item = params["item"] || %{}

    if params["turnId"] == state.provider_turn and item["type"] == "mcpToolCall" do
      emit(state, type,
        turn_id: state.turn,
        tool: item["tool"],
        tool_call_id: item["id"],
        is_error: not is_nil(item["error"])
      )
    else
      state
    end
  end

  defp complete(state, status) do
    state = emit(state, :turn_completed, turn_id: state.turn, status: status)
    %{state | turn: nil, provider_turn: nil, turn_request: nil, interrupting: false, state: :idle}
  end

  defp interrupt(%{interrupting: true, provider_turn: turn} = state) when is_binary(turn) do
    _ =
      StdioTransport.send_frame(state.transport, %{
        id: state.request,
        method: "turn/interrupt",
        params: %{threadId: state.session, turnId: turn}
      })

    %{state | request: state.request + 1, interrupting: false}
  end

  defp interrupt(state), do: state

  defp refuse(transport, id),
    do:
      StdioTransport.send_frame(transport, %{
        id: id,
        error: %{code: -32601, message: "Coordinator requests are refused"}
      })

  defp failure(code), do: Error.new(:transport, code, "Codex conversation " <> code)

  defp emit(state, type, fields) do
    ordinal = state.ordinal + 1
    send(state.owner, {:conversation_event, self(), ConversationEvent.new(type, ordinal, fields)})
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

    %{state | transport: nil, state: :closed}
  end

  defp wait_gone(groups, deadline) do
    if Enum.any?(groups, &ProcessTree.alive?/1) and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(50)
      wait_gone(groups, deadline)
    end
  end
end
