defmodule Shoestring.Harness.ClaudeHeadless.Conversation do
  @moduledoc """
  Claude Code as a coordinator conversation (`Shoestring.Harness.Conversation`).

  One long-lived `claude -p --input-format stream-json --output-format
  stream-json` process per conversation, one stdin line per turn. Phase 0
  verified the protocol offline with Claude Code 2.1.312
  (`plans/evidence/15-native-chat/`).

  Launch:

    * Read-only: `--tools=Read,Grep,Glob` offers no editing, shell or web
      tool (Phase 0: Edit, Write and Bash were refused and the checkout was
      unchanged). `--restricted`, `--setting-sources ""` (no settings, so no
      hooks or plugins), `--disable-slash-commands` and `--permission-mode
      dontAsk` are the explorer's safety set. `--safe-mode` is left out: it
      also disables MCP servers, so the coordinator could not reach
      Shoestring's tools. The repository's CLAUDE.md is therefore read.
    * Shoestring's tools: `--strict-mcp-config --mcp-config FILE` and
      `--allowedTools mcp__shoestring`. The file holds the endpoint's token,
      so it is written mode 0600 in a private directory instead of being
      passed in argv, where other users' `ps` could read it.
    * `--session-id` gives a fresh session its id before the first turn;
      `--resume` continues one.
    * `ANTHROPIC_API_KEY` is removed from the environment so the coordinator
      runs on the subscription, never a paid API key.
    * The process leads its own process group (as every port program does),
      so closing reaps everything it started.

  Opening sends the stream-json `initialize` control request and refuses
  the model, or the effort, when Claude's own listing does not offer it,
  before any turn: Claude never runs on its default model in our place.
  Claude lists whatever `--model` names, even a model it does not know, as
  an extra entry described "Custom model" (VERIFIED, 2.1.312, with
  `not-a-model`); that echo is not an offer and is ignored. A model added by
  hand (`shoestring models add`) is not in Claude's listing; the caller
  passes `allow_unlisted_model: true` for it.
  `cancel_turn/1` sends the `interrupt` control request; Claude then ends
  the turn with `result`/`error_during_execution`, reported `:interrupted`.
  """

  @behaviour Shoestring.Harness.Conversation

  use GenServer

  alias Shoestring.Harness.Capacity.Codex.StdioTransport
  alias Shoestring.Harness.ClaudeHeadless.ConversationFrames
  alias Shoestring.Harness.{Conversation, ConversationEvent, Error}
  alias Shoestring.Harness.OpencodeAcp.ProcessTree
  alias Shoestring.SandboxTemp

  @temp_prefix "shoestring-conversation"
  @max_frame_size 4 * 1024 * 1024
  @handshake_timeout_ms 30_000
  @exit_wait_ms 5_000
  @safety [
    "--restricted",
    "--setting-sources",
    "",
    "--disable-slash-commands",
    "--permission-mode",
    "dontAsk"
  ]

  # --- API ---

  @doc """
  Opens a conversation. Options: `:executable` (the `claude` path),
  `:env` (`[{name, value | false}]` applied last), `:handshake_timeout_ms`,
  `:allow_unlisted_model` (accept a model Claude does not list; its effort
  is then not checked),
  and `:exit_wait_ms` (how long closing waits for Claude to exit by itself
  before reaping; default #{@exit_wait_ms}).
  """
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

  @doc "The argv after the executable, for `spec` and the private file paths."
  @spec argv(
          Conversation.spec(),
          %{mcp_config: Path.t(), instructions: Path.t() | nil},
          String.t()
        ) ::
          [String.t()]
  def argv(spec, paths, session_id) do
    ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"] ++
      ["--model", spec.model] ++
      if(spec[:effort], do: ["--effort", spec.effort], else: []) ++
      @safety ++
      ["--tools=Read,Grep,Glob", "--strict-mcp-config", "--mcp-config", paths.mcp_config] ++
      if(spec[:tools], do: ["--allowedTools", "mcp__shoestring"], else: []) ++
      if(paths.instructions, do: ["--append-system-prompt-file", paths.instructions], else: []) ++
      if spec[:resume], do: ["--resume", session_id], else: ["--session-id", session_id]
  end

  @doc "The MCP configuration naming Shoestring's tool endpoint, or none."
  @spec mcp_config(Conversation.spec()) :: map()
  def mcp_config(%{tools: %{url: url, token: token}}),
    do: %{
      "mcpServers" => %{
        "shoestring" => %{
          "type" => "http",
          "url" => url,
          "headers" => %{"Authorization" => "Bearer " <> token}
        }
      }
    }

  def mcp_config(_spec), do: %{"mcpServers" => %{}}

  # --- Server ---

  @impl GenServer
  def init({spec, opts}) do
    Process.flag(:trap_exit, true)
    session_id = spec[:resume] || Ecto.UUID.generate()

    case open(spec, opts, session_id) do
      {:ok, state} ->
        Process.monitor(spec.owner)
        {:ok, emit(state, :session, provider_session_id: session_id)}

      # `{:error, _}` (OTP 26+) ends this process normally, so the linked
      # caller gets the refusal back instead of an exit signal.
      {:error, error, partial} ->
        cleanup(partial)
        {:error, error}
    end
  end

  defp open(spec, opts, session_id) do
    state = %{
      owner: spec.owner,
      spec: spec,
      dir: nil,
      transport: nil,
      os_pid: nil,
      ordinal: 0,
      turn: nil,
      interrupting: false,
      next_request: 1,
      session: session_id,
      state: :starting,
      malformed: 0,
      allow_unlisted_model: Keyword.get(opts, :allow_unlisted_model, false),
      exit_wait_ms: Keyword.get(opts, :exit_wait_ms, @exit_wait_ms)
    }

    case private_dir() do
      {:ok, dir} -> launch(%{state | dir: dir}, opts)
      {:error, reason} -> {:error, start_failed(reason), state}
    end
  end

  # Every failure returns the state built so far, so cleanup can remove the
  # private directory and reap a process that already started.
  defp launch(state, opts) do
    spec = state.spec

    with {:ok, paths} <- write_files(state.dir, spec),
         {:ok, executable} <- executable(opts),
         {:ok, transport} <-
           StdioTransport.start_link(
             owner: self(),
             executable: executable,
             args: argv(spec, paths, state.session),
             cd: spec.workdir,
             env: env(opts),
             max_frame_size: @max_frame_size
           ) do
      state = %{state | transport: transport, os_pid: StdioTransport.os_pid(transport)}

      case handshake(state, Keyword.get(opts, :handshake_timeout_ms, @handshake_timeout_ms)) do
        {:ok, state} -> {:ok, %{state | state: :idle}}
        {:error, error, state} -> {:error, error, state}
      end
    else
      {:error, %Error{} = error} -> {:error, error, state}
      {:error, reason} -> {:error, start_failed(reason), state}
    end
  end

  defp start_failed(reason), do: Error.new(:transport, "start_failed", inspect(reason))

  defp private_dir do
    with {:ok, dir} <- SandboxTemp.create(@temp_prefix),
         :ok <- File.chmod(dir, 0o700) do
      {:ok, dir}
    end
  end

  defp write_files(dir, spec) do
    mcp = Path.join(dir, "mcp.json")

    with :ok <- write_private(mcp, Jason.encode!(mcp_config(spec))) do
      case spec[:instructions] do
        text when is_binary(text) and text != "" ->
          instructions = Path.join(dir, "instructions.md")

          with :ok <- write_private(instructions, text),
               do: {:ok, %{mcp_config: mcp, instructions: instructions}}

        _ ->
          {:ok, %{mcp_config: mcp, instructions: nil}}
      end
    end
  end

  # Created empty with mode 0600 before anything is written to it.
  defp write_private(path, content) do
    with :ok <- File.write(path, "", [:exclusive]),
         :ok <- File.chmod(path, 0o600) do
      File.write(path, content)
    end
  end

  defp executable(opts) do
    case Keyword.get(opts, :executable) || System.find_executable("claude") do
      nil -> {:error, Error.new(:transport, "binary_missing", "claude is not on PATH")}
      path -> {:ok, path}
    end
  end

  defp env(opts) do
    base = [{"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1"}, {"ANTHROPIC_API_KEY", false}]

    Enum.reduce(Keyword.get(opts, :env, []), base, fn {key, value}, acc ->
      List.keystore(acc, key, 0, {key, value})
    end)
  end

  # `initialize`, then the model and effort check against Claude's listing.
  defp handshake(state, timeout) do
    state = control(state, "initialize", %{"subtype" => "initialize"})
    deadline = System.monotonic_time(:millisecond) + timeout
    await_initialize(state, deadline)
  end

  defp await_initialize(state, deadline) do
    transport = state.transport
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:codex_transport_frame, ^transport, line} ->
        case decode(line) do
          {:ok, frame} ->
            case ConversationFrames.classify(frame) do
              {:control_response, "initialize", response} -> offered(state, response)
              _ -> await_initialize(state, deadline)
            end

          :error ->
            await_initialize(%{state | malformed: state.malformed + 1}, deadline)
        end

      {:codex_transport_error, ^transport, :oversized_frame} ->
        {:error, Error.new(:transport, "oversized_frame", "Line cap exceeded; output refused"),
         state}

      {:codex_transport_closed, ^transport, reason} ->
        {:error, Error.new(:transport, "exited_during_handshake", inspect(reason)), state}
    after
      wait ->
        {:error, Error.new(:transport, "handshake_timeout", "claude did not answer initialize"),
         state}
    end
  end

  defp offered(state, %{"subtype" => "success", "response" => %{"models" => models}})
       when is_list(models) do
    spec = state.spec

    offers = Enum.reject(models, &(&1["description"] == "Custom model"))

    case Enum.find(offers, &(spec.model in [&1["value"], &1["resolvedModel"]])) do
      nil when state.allow_unlisted_model ->
        {:ok, state}

      nil ->
        {:error,
         Error.new(
           :schema_incompatible,
           "model_not_offered",
           "Claude does not offer #{spec.model}"
         ), state}

      model ->
        efforts = List.wrap(model["supportedEffortLevels"])

        if is_nil(spec[:effort]) or spec.effort in efforts,
          do: {:ok, state},
          else:
            {:error,
             Error.new(
               :schema_incompatible,
               "effort_not_offered",
               "#{spec.model} does not offer effort #{spec.effort}"
             ), state}
    end
  end

  defp offered(state, response),
    do: {:error, Error.new(:transport, "initialize_refused", inspect(response["subtype"])), state}

  @impl GenServer
  def handle_call({:turn, _turn_id, _text}, _from, %{turn: running} = state)
      when not is_nil(running),
      do: {:reply, {:error, Conversation.turn_in_progress(running)}, state}

  def handle_call({:turn, turn_id, text}, _from, state) do
    frame = %{"type" => "user", "message" => %{"role" => "user", "content" => text}}

    case StdioTransport.send_frame(state.transport, frame) do
      :ok ->
        state = %{state | turn: turn_id, interrupting: false, state: :in_turn}
        {:reply, :ok, emit(state, :turn_started, turn_id: turn_id)}

      {:error, reason} ->
        {:reply, {:error, Error.new(:transport, "send_failed", inspect(reason))}, state}
    end
  end

  def handle_call(:cancel_turn, _from, %{turn: nil} = state), do: {:reply, :ok, state}
  def handle_call(:cancel_turn, _from, %{interrupting: true} = state), do: {:reply, :ok, state}

  def handle_call(:cancel_turn, _from, state) do
    state = control(state, "interrupt-#{state.next_request}", %{"subtype" => "interrupt"})
    {:reply, :ok, %{state | interrupting: true}}
  end

  def handle_call(:close, _from, state) do
    {:stop, :normal, :ok, shutdown(state, :normal)}
  end

  def handle_call(:status, _from, state),
    do:
      {:reply, %{state: state.state, turn_id: state.turn, provider_session_id: state.session},
       state}

  @impl GenServer
  def handle_info({:codex_transport_frame, transport, line}, %{transport: transport} = state) do
    case decode(line) do
      {:ok, frame} -> {:noreply, frame(state, ConversationFrames.classify(frame))}
      :error -> {:noreply, %{state | malformed: state.malformed + 1}}
    end
  end

  def handle_info(
        {:codex_transport_error, transport, :oversized_frame},
        %{transport: transport} = state
      ),
      do: {:stop, :normal, shutdown(state, :oversized_frame)}

  def handle_info({:codex_transport_closed, transport, reason}, %{transport: transport} = state),
    do: {:stop, :normal, shutdown(%{state | transport: nil}, {:exited, reason})}

  def handle_info({:DOWN, _ref, :process, owner, _reason}, %{owner: owner} = state),
    do: {:stop, :normal, shutdown(state, :owner_down)}

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    if state.state != :closed, do: cleanup(state)
    :ok
  end

  # --- Frames ---

  defp frame(state, {:init, id}) when id == state.session, do: state

  defp frame(state, {:init, id}) do
    %{state | session: id} |> emit(:session, provider_session_id: id)
  end

  defp frame(%{turn: nil} = state, {:items, _items}), do: state

  defp frame(state, {:items, items}) do
    Enum.reduce(items, state, fn
      {:text, text}, acc ->
        emit(acc, :text, turn_id: acc.turn, text: text)

      {:tool_call, tool, id}, acc ->
        emit(acc, :tool_call, turn_id: acc.turn, tool: tool, tool_call_id: id)

      {:tool_result, id, error?}, acc ->
        emit(acc, :tool_result, turn_id: acc.turn, tool_call_id: id, is_error: error?)
    end)
  end

  defp frame(%{turn: nil} = state, {:result, _result}), do: state

  defp frame(state, {:result, result}) do
    status =
      cond do
        result.success -> :completed
        state.interrupting -> :interrupted
        true -> :failed
      end

    state
    |> emit(:turn_completed, turn_id: state.turn, status: status, usage: result.usage)
    |> Map.merge(%{turn: nil, interrupting: false, state: :idle})
  end

  defp frame(state, _ignored), do: state

  # --- Plumbing ---

  defp control(state, request_id, request) do
    frame = %{"type" => "control_request", "request_id" => request_id, "request" => request}
    _ = StdioTransport.send_frame(state.transport, frame)
    %{state | next_request: state.next_request + 1}
  end

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, %{} = frame} -> {:ok, frame}
      _ -> :error
    end
  end

  defp emit(state, type, fields) do
    ordinal = state.ordinal + 1
    send(state.owner, {:conversation_event, self(), ConversationEvent.new(type, ordinal, fields)})
    %{state | ordinal: ordinal}
  end

  # Close stdin so Claude can save its session and exit; wait for its
  # process groups, then reap whatever is left. The last event is :closed.
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

    _ = SandboxTemp.remove(state.dir, @temp_prefix)
    %{state | transport: nil, state: :closed}
  end

  defp wait_gone(groups, deadline) do
    if Enum.any?(groups, &ProcessTree.alive?/1) and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(50)
      wait_gone(groups, deadline)
    end
  end
end
