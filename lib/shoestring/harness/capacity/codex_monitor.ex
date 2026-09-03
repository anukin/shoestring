defmodule Shoestring.Harness.Capacity.CodexMonitor do
  @moduledoc """
  Supervised Codex capacity monitor GenServer.

  Manages an official `codex app-server --stdio` connection, executes the
  evidenced initialize/account handshake and rate-limit read sequence, consumes
  sparse rate-limit update notifications, and normalizes telemetry into canonical
  `CapacitySnapshot` v2 events ingested into the Capacity Observatory ledger.

  Adheres strictly to the Gate 0A support matrix and contract boundaries:
  - Discovers installed CLI version and evaluates compatibility before connecting.
  - Correctly frames and correlates JSON-RPC requests/responses and tolerates
    interleaved notifications.
  - Bounding on pending requests, frame sizes, and backoff exponential intervals.
  - Merges sparse update notifications into last-known provider state without
    erasing omitted windows.
  - Classifies quota refusal, schema drift, process exits, and transport errors
    fail-closed while safely preserving last-known observations.
  - Never initiates coding or model inference turns merely to refresh capacity.
  - Never logs or persists sensitive credentials, tokens, or raw account data.
  """

  @behaviour Shoestring.Harness.Capacity.Source

  use GenServer
  require Logger

  alias Shoestring.Harness.{Capacity, CapacitySnapshot, Error, Observatory}

  @type status ::
          :connected
          | :disconnected
          | :backoff
          | :unavailable
          | :auth_required
          | :refused
          | :incompatible_schema
          | :incompatible
          | :sink_error

  @default_max_frame_size 262_144
  @default_max_pending_requests 10
  @default_request_timeout_ms 10_000
  @default_base_backoff_ms 1_000
  @default_max_backoff_ms 30_000
  @default_scope "subscription"
  @default_client_info %{
    "name" => "shoestring_codex_monitor",
    "title" => "Shoestring Codex Capacity Monitor",
    "version" => "0.1.0"
  }

  defstruct [
    :status,
    :connection_phase,
    :discovered_version,
    :compatibility,
    :last_observation,
    :last_known_provider_state,
    :account_info,
    :transport_mod,
    :transport_opts,
    :transport_pid,
    :configured_transport_pid,
    :transport_ref,
    :sink,
    :clock,
    :pending_requests,
    :next_id,
    :max_pending_requests,
    :request_timeout_ms,
    :max_frame_size,
    :base_backoff_ms,
    :max_backoff_ms,
    :backoff_attempt,
    :backoff_fn,
    :random_fn,
    :reconnect_timer,
    :connection_generation,
    :scope,
    :client_info
  ]

  # --- Public Client API ---

  @doc """
  Starts the CodexMonitor process.
  """
  def start_link(opts \\ []) do
    name =
      case Keyword.get(opts, :name, __MODULE__) do
        false -> nil
        nil -> nil
        other -> other
      end

    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Returns the current explicit status of the monitor.

  Possible values:
  - `:connected` - healthy connection with compatible version and valid observations
  - `:disconnected` - transport not active (e.g. before initial connection or explicitly stopped)
  - `:backoff` - transient transport disconnected or failed while connected, currently waiting to reconnect
  - `:unavailable` - transport failed repeatedly or before connection completed
  - `:auth_required` - provider indicated authentication / login is required
  - `:incompatible_schema` - untested CLI version, parse error, or unrecognized schema. (connected? == true meaning transport up, but capacity not guaranteed)
  - `:refused` - structured quota refusal. (connected? == true meaning transport up, but NOT dispatchable/available)
  - `:sink_error` - persistence failed. (connected? == true meaning transport up, but capacity not dispatchable)
  - `:incompatible` - provider CLI missing or incompatible mode/version
  """
  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @doc "Returns the latest normalized CapacitySnapshot or nil."
  @spec last_observation(GenServer.server()) :: CapacitySnapshot.t() | nil
  def last_observation(server \\ __MODULE__) do
    GenServer.call(server, :last_observation)
  end

  @doc "Returns a structured diagnostic map of the monitor's state."
  @spec get_status(GenServer.server()) :: map()
  def get_status(server \\ __MODULE__) do
    GenServer.call(server, :get_status)
  end

  @doc """
  Triggers an explicit rate-limit read over the active transport.

  Blocks until the provider response is received, normalized, and ingested,
  or until timeout occurs.
  """
  @spec read_capacity(GenServer.server(), timeout()) ::
          {:ok, CapacitySnapshot.t()} | {:error, term()}
  def read_capacity(server \\ __MODULE__, timeout \\ 5_000) do
    GenServer.call(server, {:read_capacity, timeout}, timeout + 2_000)
  end

  @doc "Explicitly disconnects the current transport session without exiting the monitor."
  @spec disconnect(GenServer.server()) :: :ok
  def disconnect(server \\ __MODULE__) do
    GenServer.call(server, :disconnect)
  end

  @doc "Triggers an immediate reconnect attempt, canceling any pending backoff timer."
  @spec reconnect(GenServer.server()) :: :ok
  def reconnect(server \\ __MODULE__) do
    GenServer.call(server, :reconnect)
  end

  # --- Capacity.Source Behaviour ---

  @doc """
  Returns the base provenance map for the codex app_server_stdio adapter.

  Note on limitations: Since this function takes no server argument, it hardcodes `GenServer.whereis(__MODULE__)`.
  Named or test instances that do not register globally as `__MODULE__` will receive the `:explicit_read` fallback.
  Additionally, calling this function from inside the monitor process itself would deadlock because `last_observation` relies on a `GenServer.call`.
  """
  @impl Shoestring.Harness.Capacity.Source
  def provenance do
    event =
      case GenServer.whereis(__MODULE__) do
        nil ->
          :explicit_read

        pid ->
          case last_observation(pid) do
            %CapacitySnapshot{source: %{event: ev}} -> ev
            _ -> :explicit_read
          end
      end

    %{
      adapter_id: "codex_app_server_stdio",
      provider_id: "codex",
      invocation_mode: "app_server_stdio",
      event: event
    }
  end

  @impl Shoestring.Harness.Capacity.Source
  def support_tier, do: :proactive

  @impl Shoestring.Harness.Capacity.Source
  def observe(opts \\ %{})

  def observe(server) when is_pid(server) or is_atom(server) do
    observe(server, %{})
  end

  def observe(opts) when is_map(opts) do
    observe(__MODULE__, opts)
  end

  def observe(server, opts) when is_map(opts) or is_list(opts) do
    opts_map = if is_list(opts), do: Map.new(opts), else: opts
    fresh? = Map.get(opts_map, :fresh, false) or Map.get(opts_map, "fresh", false)

    case GenServer.whereis(server) do
      nil ->
        {:error,
         Error.new(
           :transport,
           "source_unavailable",
           "CodexMonitor is not running"
         )}

      pid when is_pid(pid) ->
        if fresh? do
          case read_capacity(pid) do
            {:ok, snapshot} ->
              {:ok, snapshot}

            {:error, reason} ->
              {:error,
               Error.new(
                 :transport,
                 "read_failed",
                 "Failed to read capacity: #{inspect(reason)}"
               )}
          end
        else
          case last_observation(pid) do
            %CapacitySnapshot{} = snapshot ->
              {:ok, snapshot}

            nil ->
              {:error,
               Error.new(
                 :transport,
                 "no_observation",
                 "No capacity observation available from CodexMonitor"
               )}
          end
        end
    end
  end

  # --- GenServer Callbacks ---

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    transport_mod =
      Keyword.get(opts, :transport, Shoestring.Harness.Capacity.Codex.StdioTransport)

    transport_opts = Keyword.get(opts, :transport_opts, [])
    sink = Keyword.get(opts, :sink, &Observatory.ingest/1)
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)

    scope = Keyword.get(opts, :scope, @default_scope)
    client_info = Keyword.get(opts, :client_info, @default_client_info)
    max_frame_size = Keyword.get(opts, :max_frame_size, @default_max_frame_size)
    max_pending = Keyword.get(opts, :max_pending_requests, @default_max_pending_requests)
    req_timeout = Keyword.get(opts, :request_timeout_ms, @default_request_timeout_ms)
    base_backoff = Keyword.get(opts, :base_backoff_ms, @default_base_backoff_ms)
    max_backoff = Keyword.get(opts, :max_backoff_ms, @default_max_backoff_ms)
    backoff_fn = Keyword.get(opts, :backoff_fn)
    random_fn = Keyword.get(opts, :random_fn)
    auto_connect? = Keyword.get(opts, :auto_connect, true)
    configured_transport_pid = Keyword.get(opts, :transport_pid)

    # Phase 1 & 2: Version discovery and compatibility evaluation
    {version, compat, initial_status} = evaluate_initial_compatibility(opts)

    state = %__MODULE__{
      status: initial_status,
      connection_phase:
        if(initial_status == :incompatible, do: :incompatible, else: :unconnected),
      discovered_version: version,
      compatibility: compat,
      last_observation: nil,
      last_known_provider_state: nil,
      account_info: nil,
      transport_mod: transport_mod,
      transport_opts: transport_opts,
      transport_pid: configured_transport_pid,
      configured_transport_pid: configured_transport_pid,
      transport_ref: nil,
      sink: sink,
      clock: clock,
      pending_requests: %{},
      next_id: 1,
      max_pending_requests: max_pending,
      request_timeout_ms: req_timeout,
      max_frame_size: max_frame_size,
      base_backoff_ms: base_backoff,
      max_backoff_ms: max_backoff,
      backoff_attempt: 0,
      backoff_fn: backoff_fn,
      random_fn: random_fn,
      reconnect_timer: nil,
      connection_generation: 0,
      scope: scope,
      client_info: client_info
    }

    if initial_status != :incompatible and auto_connect? do
      {:ok, state, {:continue, :connect}}
    else
      {:ok, state}
    end
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    {:noreply, do_connect(state)}
  end

  # --- Client Calls ---

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  def handle_call(:last_observation, _from, state) do
    {:reply, state.last_observation, state}
  end

  def handle_call(:get_status, _from, state) do
    summary = %{
      status: state.status,
      connection_phase: state.connection_phase,
      last_observation: state.last_observation,
      discovered_version: state.discovered_version,
      compatibility: state.compatibility,
      account_info: state.account_info,
      backoff_attempt: state.backoff_attempt,
      connected?:
        state.status in [:connected, :incompatible_schema, :refused, :sink_error] and
          state.connection_phase == :connected,
      pending_request_count: map_size(state.pending_requests),
      transport_pid: state.transport_pid,
      reconnect_timer: state.reconnect_timer
    }

    {:reply, summary, state}
  end

  def handle_call({:read_capacity, timeout}, from, state) do
    cond do
      state.status not in [:connected, :incompatible_schema, :refused, :sink_error] or
          state.connection_phase != :connected ->
        {:reply, {:error, :not_connected}, state}

      map_size(state.pending_requests) >= state.max_pending_requests ->
        {:reply, {:error, :too_many_pending_requests}, state}

      true ->
        state =
          send_request(
            state,
            "account/rateLimits/read",
            %{},
            {:client_read, from},
            timeout
          )

        {:noreply, state}
    end
  end

  def handle_call(:disconnect, _from, state) do
    state = cleanup_transport(state, :disconnected)
    {:reply, :ok, %{state | status: :disconnected, connection_phase: :unconnected}}
  end

  def handle_call(:reconnect, _from, state) do
    state = cleanup_transport(state, :reconnect)
    state = %{state | backoff_attempt: 0}
    {:reply, :ok, do_connect(state)}
  end

  # --- Transport & Message Handling ---

  @impl GenServer
  def handle_info({:codex_transport_connected, transport_pid}, state) do
    if state.transport_pid == transport_pid do
      # Connected! Begin handshake with initialize
      state =
        send_request(
          state,
          "initialize",
          %{"clientInfo" => state.client_info},
          :handshake_initialize
        )

      {:noreply, %{state | connection_phase: :initializing}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:codex_transport_frame, transport_pid, raw_frame}, state) do
    if state.transport_pid == transport_pid do
      {:noreply, process_incoming_frame(raw_frame, state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:codex_transport_error, transport_pid, reason}, state) do
    if state.transport_pid == transport_pid do
      handle_transport_failure(state, {:transport_error, reason})
    else
      {:noreply, state}
    end
  end

  def handle_info({:codex_transport_closed, transport_pid, reason}, state) do
    if state.transport_pid == transport_pid do
      handle_transport_failure(state, {:transport_closed, reason})
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    if state.transport_ref == ref or state.transport_pid == pid do
      handle_transport_failure(state, {:process_down, reason})
    else
      {:noreply, state}
    end
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending_requests, id) do
      {nil, _} ->
        {:noreply, state}

      {%{caller: caller, context: context}, remaining_requests} ->
        state = %{state | pending_requests: remaining_requests}

        case context do
          {:client_read, from} ->
            GenServer.reply(from, {:error, :timeout})
            {:noreply, state}

          :handshake_initialize ->
            handle_transport_failure(state, {:handshake_timeout, "initialize"})

          :handshake_account ->
            handle_transport_failure(state, {:handshake_timeout, "account/read"})

          :handshake_rate_limits ->
            handle_transport_failure(state, {:handshake_timeout, "account/rateLimits/read"})

          _ ->
            if caller, do: GenServer.reply(caller, {:error, :timeout})
            {:noreply, state}
        end
    end
  end

  def handle_info(:reconnect, state) do
    state = %{state | reconnect_timer: nil}

    if state.status == :backoff or state.connection_phase == :backoff do
      {:noreply, do_connect(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_other, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    cleanup_transport(state, :terminate)
    :ok
  end

  # --- Connection & Handshake Logic ---

  defp evaluate_initial_compatibility(opts) do
    runner = Keyword.get(opts, :runner, Shoestring.Harness.Capacity.SystemCommandRunner)
    explicit_version = Keyword.get(opts, :version)

    version_result =
      if explicit_version do
        {:ok, %{raw: explicit_version, version: explicit_version}}
      else
        Capacity.discover_version(:codex, runner: runner)
      end

    case version_result do
      {:ok, %{version: version}} ->
        compat = Capacity.compatibility(:codex, :app_server_stdio, version)

        case compat.compatibility_state do
          :incompatible ->
            {version, compat, :incompatible}

          :degraded ->
            {version, compat, :incompatible_schema}

          :compatible ->
            {version, compat, :disconnected}
        end

      {:error, _reason} ->
        compat = Capacity.compatibility(:codex, :app_server_stdio, nil)
        {nil, compat, :incompatible}
    end
  end

  defp do_connect(state) do
    # Cancel any existing reconnect timer
    if state.reconnect_timer do
      Process.cancel_timer(state.reconnect_timer)
    end

    target_pid = state.transport_pid || state.configured_transport_pid

    if target_pid && Process.alive?(target_pid) do
      # Ensure injected transport delivers frames to this monitor
      try do
        GenServer.call(target_pid, {:set_owner, self()})
      catch
        :exit, _ -> :ok
      end

      ref = Process.monitor(target_pid)
      send(self(), {:codex_transport_connected, target_pid})

      %{
        state
        | transport_pid: target_pid,
          transport_ref: ref,
          reconnect_timer: nil,
          connection_phase: :connecting
      }
    else
      state = cleanup_transport(state, :reconnecting)

      opts =
        Keyword.merge(state.transport_opts,
          owner: self(),
          max_frame_size: state.max_frame_size
        )

      case state.transport_mod.start_link(opts) do
        {:ok, pid} ->
          ref = Process.monitor(pid)

          %{
            state
            | transport_pid: pid,
              transport_ref: ref,
              reconnect_timer: nil,
              connection_phase: :connecting
          }

        {:error, reason} ->
          schedule_backoff(state, {:transport_start_failed, reason})
      end
    end
  end

  defp send_request(state, method, params, context, timeout \\ nil) do
    raw_id = state.next_id
    id = "#{state.connection_generation || 0}:#{raw_id}"
    timeout_ms = timeout || state.request_timeout_ms
    timer_ref = Process.send_after(self(), {:request_timeout, id}, timeout_ms)

    request_map = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    }

    pending_entry = %{
      method: method,
      context: context,
      caller:
        case context do
          {:client_read, from} -> from
          _ -> nil
        end,
      timer_ref: timer_ref,
      sent_at: call_clock(state.clock)
    }

    updated_pending = Map.put(state.pending_requests, id, pending_entry)
    state = %{state | pending_requests: updated_pending, next_id: raw_id + 1}

    if state.transport_pid do
      state.transport_mod.send_frame(state.transport_pid, request_map)
    end

    state
  end

  defp send_notification(state, method, params) do
    notification_map = %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params
    }

    if state.transport_pid do
      state.transport_mod.send_frame(state.transport_pid, notification_map)
    end

    state
  end

  # --- Frame Processing ---

  defp process_incoming_frame(raw_frame, state) do
    cond do
      is_binary(raw_frame) and byte_size(raw_frame) > state.max_frame_size ->
        Logger.warning("Codex JSON-RPC frame rejected: oversized frame")
        state

      true ->
        case decode_frame(raw_frame) do
          {:ok, decoded} when is_map(decoded) ->
            handle_decoded_message(decoded, state)

          {:error, _parse_err} ->
            Logger.warning("Codex JSON-RPC malformed frame rejected")
            state
        end
    end
  end

  defp decode_frame(frame) when is_map(frame), do: {:ok, frame}

  defp decode_frame(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} -> {:ok, decoded}
      error -> error
    end
  end

  defp decode_frame(_), do: {:error, :unsupported_frame_type}

  defp handle_decoded_message(%{"id" => id} = message, state) when not is_nil(id) do
    # JSON-RPC Response matching a request
    current_gen_prefix = "#{state.connection_generation || 0}:"

    if is_binary(id) and String.starts_with?(id, current_gen_prefix) do
      case Map.pop(state.pending_requests, id) do
        {nil, _} ->
          state

        {pending_entry, remaining_requests} ->
          Process.cancel_timer(pending_entry.timer_ref)
          state = %{state | pending_requests: remaining_requests}
          handle_request_response(pending_entry, message, state)
      end
    else
      state
    end
  end

  defp handle_decoded_message(%{"method" => method} = message, state) do
    # JSON-RPC Notification
    handle_notification(method, Map.get(message, "params", %{}), state)
  end

  defp handle_decoded_message(_other, state) do
    # Unrecognized frame structure: ignore safely
    state
  end

  # --- Response Handlers ---

  defp handle_request_response(
         %{context: :handshake_initialize},
         %{"result" => result},
         state
       ) do
    # Handshake Phase 1 OK: Send initialized notification, then account/read
    _safe_platform = extract_safe_platform(result)
    state = send_notification(state, "initialized", %{})

    state =
      send_request(
        state,
        "account/read",
        %{"refreshToken" => false},
        :handshake_account
      )

    %{state | connection_phase: :reading_account}
  end

  defp handle_request_response(
         %{context: :handshake_initialize},
         %{"error" => _error},
         state
       ) do
    fail_and_schedule_backoff(state, {:handshake_failed, "initialize"})
  end

  defp handle_request_response(
         %{context: :handshake_account},
         %{"result" => result},
         state
       ) do
    account = Map.get(result, "account")
    requires_openai_auth = Map.get(result, "requiresOpenaiAuth", false)

    auth_required? =
      is_nil(account) or
        account == %{} or
        is_nil(account["type"]) or
        account["authMode"] == "unauthenticated" or
        (requires_openai_auth == true and (is_nil(account) or account == %{}))

    if auth_required? do
      %{
        state
        | status: :auth_required,
          connection_phase: :auth_required,
          account_info: %{requires_auth: true}
      }
    else
      safe_account = extract_safe_account(account)
      state = %{state | account_info: safe_account}

      state =
        send_request(
          state,
          "account/rateLimits/read",
          %{},
          :handshake_rate_limits
        )

      %{state | connection_phase: :reading_rate_limits}
    end
  end

  defp handle_request_response(
         %{context: :handshake_account},
         %{"error" => error},
         state
       ) do
    # If account/read errors with auth refusal or unauthenticated
    if is_auth_error?(error) do
      %{state | status: :auth_required, connection_phase: :auth_required}
    else
      fail_and_schedule_backoff(state, {:handshake_failed, "account/read"})
    end
  end

  defp handle_request_response(
         %{context: :handshake_rate_limits},
         %{"result" => result},
         state
       ) do
    now = call_clock(state.clock)

    case ingest_new_observation(result, state, :explicit_read, now) do
      {:ok, _snapshot, state} ->
        # Handshake sequence completely successful!
        %{
          state
          | connection_phase: :connected,
            backoff_attempt: 0
        }

      {:error, _reason, state} ->
        # Observation ingestion or normalization failed
        fail_and_schedule_backoff(state, :initial_observation_failed)
    end
  end

  defp handle_request_response(
         %{context: :handshake_rate_limits},
         %{"error" => _error},
         state
       ) do
    fail_and_schedule_backoff(state, {:handshake_failed, "account/rateLimits/read"})
  end

  defp handle_request_response(
         %{context: {:client_read, from}},
         %{"result" => result},
         state
       ) do
    now = call_clock(state.clock)

    case ingest_new_observation(result, state, :explicit_read, now) do
      {:ok, snapshot, state} ->
        new_status = resolve_operational_status(snapshot, state)
        GenServer.reply(from, {:ok, snapshot})
        %{state | status: new_status}

      {:error, reason, state} ->
        GenServer.reply(from, {:error, reason})
        state
    end
  end

  defp handle_request_response(
         %{context: {:client_read, from}},
         %{"error" => error},
         state
       ) do
    GenServer.reply(from, {:error, error})
    state
  end

  defp handle_request_response(_pending, _message, state), do: state

  # --- Notification Handlers ---

  defp handle_notification("account/rateLimits/updated", params, state) do
    now = call_clock(state.clock)

    case ingest_new_observation(params, state, :update_notification, now) do
      {:ok, _snapshot, state} ->
        state

      {:error, _reason, state} ->
        # Keep last known observation intact, mark degraded
        %{state | status: :incompatible_schema}
    end
  end

  defp handle_notification("account/updated", params, state) do
    safe_account = extract_safe_account(params)

    auth_required? =
      params["authMode"] == "unauthenticated" or
        params["loggedIn"] == false

    if auth_required? do
      %{state | status: :auth_required, connection_phase: :auth_required}
    else
      %{state | account_info: safe_account}
    end
  end

  defp handle_notification(_method, _params, state) do
    # Ignore unknown notifications safely
    state
  end

  # --- Observation Normalization, Sparse Merge, and Ingestion ---

  defp ingest_new_observation(new_payload, state, source_event, now) do
    merged_payload = merge_provider_state(state.last_known_provider_state, new_payload)

    opts = [
      version: state.discovered_version,
      now: now,
      captured_at: now,
      source_event: source_event,
      scope: state.scope,
      last_known_snapshot: state.last_observation
    ]

    case Capacity.normalize(:codex, :app_server_stdio, merged_payload, opts) do
      {:ok, %CapacitySnapshot{} = snapshot} ->
        # Ingest through injectable sink (defaulting to Capacity Observatory)
        case safe_ingest(state.sink, snapshot) do
          :ok ->
            new_status = resolve_operational_status(snapshot, state, false)

            {:ok, snapshot,
             %{
               state
               | status: new_status,
                 last_observation: snapshot,
                 last_known_provider_state: merged_payload
             }}

          {:error, _sink_err} ->
            # Sink failure: preserve observation in memory, but fail-closed degraded
            {:ok, snapshot,
             %{
               state
               | status: :sink_error,
                 last_observation: snapshot,
                 last_known_provider_state: merged_payload
             }}
        end

      {:error, reason} ->
        # Normalization rejected payload (e.g. malformed or secrets detected)
        case preserve_observation_on_error(state, "normalization_failed", now) do
          {:ok, preserved_snapshot} ->
            {:error, reason,
             %{state | last_observation: preserved_snapshot, status: :incompatible_schema}}

          _ ->
            {:error, reason, %{state | status: :incompatible_schema}}
        end
    end
  end

  defp safe_ingest(sink, snapshot) do
    case sink.(snapshot) do
      {:ok, :persisted, _} ->
        :ok

      {:ok, :deduplicated, _} ->
        :ok

      {:ok, _} ->
        :ok

      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Codex capacity sink rejected snapshot: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("Codex capacity sink raised exception: #{Exception.message(e)}")
      {:error, e}
  end

  defp preserve_observation_on_error(state, reason, now) do
    case state.last_observation do
      %CapacitySnapshot{} = last_known ->
        case Capacity.preserve_last_known(last_known, reason, now: now) do
          {:ok, preserved} ->
            _ = safe_ingest(state.sink, preserved)
            {:ok, preserved}

          error ->
            error
        end

      nil ->
        {:error, :no_prior_observation}
    end
  end

  # --- Sparse Merge Implementation ---

  @doc """
  Merges a sparse update notification or partial payload into the last-known
  provider state without erasing omitted windows or metadata fields.
  """
  def merge_provider_state(nil, new_payload), do: new_payload
  def merge_provider_state(last_known, nil), do: last_known

  def merge_provider_state(last_known, new_payload)
      when is_map(last_known) and is_map(new_payload) do
    last_rl = extract_rate_limits_map(last_known)
    new_rl = extract_rate_limits_map(new_payload)

    merged_rl = merge_rate_limits_containers(last_rl, new_rl)

    last_container = last_known["result"] || last_known["params"] || last_known
    new_container = new_payload["result"] || new_payload["params"] || new_payload

    merged_container =
      last_container
      |> Map.delete("rateLimits")
      |> Map.merge(Map.delete(new_container, "rateLimits"), fn _k, v1, v2 ->
        if is_nil(v2), do: v1, else: v2
      end)
      |> Map.put("rateLimits", merged_rl)

    %{"result" => merged_container}
  end

  def merge_provider_state(last_known, _other), do: last_known

  defp extract_rate_limits_map(payload) when is_map(payload) do
    payload["rateLimits"] ||
      get_in(payload, ["result", "rateLimits"]) ||
      get_in(payload, ["params", "rateLimits"]) ||
      %{}
  end

  defp extract_rate_limits_map(_), do: %{}

  defp merge_rate_limits_containers(last_rl, new_rl)
       when is_map(last_rl) and is_map(new_rl) do
    primary = merge_window_entry(last_rl["primary"], new_rl["primary"])
    secondary = merge_window_entry(last_rl["secondary"], new_rl["secondary"])

    # Merge top-level rateLimits fields (e.g. planType, rateLimitReachedType)
    last_rl
    |> Map.merge(new_rl, fn
      "primary", _v1, _v2 -> primary
      "secondary", _v1, _v2 -> secondary
      _key, v1, v2 -> if is_nil(v2), do: v1, else: v2
    end)
    |> Map.put("primary", primary)
    |> Map.put("secondary", secondary)
  end

  defp merge_rate_limits_containers(last_rl, _new_rl), do: last_rl

  defp merge_window_entry(last_w, nil), do: last_w
  defp merge_window_entry(nil, new_w), do: new_w

  defp merge_window_entry(last_w, new_w) when is_map(last_w) and is_map(new_w) do
    Map.merge(last_w, new_w, fn _k, v1, v2 ->
      if is_nil(v2), do: v1, else: v2
    end)
  end

  defp merge_window_entry(last_w, _other), do: last_w

  # --- Status Resolution & Classification ---

  defp resolve_operational_status(%CapacitySnapshot{} = snapshot, state, sink_error? \\ false) do
    cond do
      sink_error? ->
        :sink_error

      snapshot.capacity_state == :refused ->
        :refused

      state.compatibility.compatibility_state == :degraded ->
        :incompatible_schema

      snapshot.capacity_state == :degraded ->
        :incompatible_schema

      true ->
        :connected
    end
  end

  defp is_auth_error?(%{"code" => code}) when code in [-32001, 401, 403], do: true

  defp is_auth_error?(%{"message" => msg}) when is_binary(msg) do
    down = String.downcase(msg)
    String.contains?(down, "auth") or String.contains?(down, "login")
  end

  defp is_auth_error?(_), do: false

  # --- Failure Handling & Exponential Backoff ---

  defp fail_and_schedule_backoff(state, reason) do
    now = call_clock(state.clock)

    # Preserve last known observation with degraded status
    state =
      case preserve_observation_on_error(state, "transport_failure", now) do
        {:ok, degraded_snapshot} ->
          %{state | last_observation: degraded_snapshot}

        _ ->
          state
      end

    schedule_backoff(state, reason)
  end

  defp handle_transport_failure(state, reason) do
    {:noreply, fail_and_schedule_backoff(state, reason)}
  end

  defp schedule_backoff(state, _reason) do
    state = cleanup_transport(state, :backoff)
    new_attempt = state.backoff_attempt + 1

    delay =
      if state.backoff_fn do
        state.backoff_fn.(new_attempt) |> max(0) |> min(state.max_backoff_ms)
      else
        calculate_backoff_delay(
          new_attempt,
          state.base_backoff_ms,
          state.max_backoff_ms,
          state.random_fn
        )
      end

    timer_ref = Process.send_after(self(), :reconnect, delay)

    new_status =
      if state.connection_phase == :connected or state.status == :backoff do
        :backoff
      else
        :unavailable
      end

    %{
      state
      | status: new_status,
        connection_phase: :backoff,
        backoff_attempt: new_attempt,
        reconnect_timer: timer_ref
    }
  end

  defp calculate_backoff_delay(attempt, base_ms, max_ms, random_fn) do
    factor = :math.pow(2, max(0, attempt - 1))
    raw_delay = min(base_ms * factor, max_ms) |> round()

    # Full jitter: random between 0 and raw_delay / 4
    max_jitter = div(raw_delay, 4) + 1

    jitter =
      cond do
        random_fn -> random_fn.(max_jitter)
        true -> :rand.uniform(max_jitter)
      end

    min(raw_delay + jitter, max_ms)
  end

  defp cleanup_transport(state, _reason) do
    if state.reconnect_timer do
      Process.cancel_timer(state.reconnect_timer)
    end

    if state.transport_ref do
      Process.demonitor(state.transport_ref, [:flush])
    end

    if is_pid(state.transport_pid) and Process.alive?(state.transport_pid) and
         is_nil(state.configured_transport_pid) do
      try do
        state.transport_mod.close(state.transport_pid)
      catch
        :exit, _ -> :ok
      end
    end

    # Fail all pending synchronous callers
    Enum.each(state.pending_requests, fn {_id, entry} ->
      Process.cancel_timer(entry.timer_ref)
      if entry.caller, do: GenServer.reply(entry.caller, {:error, :transport_closed})
    end)

    new_generation = (state.connection_generation || 0) + 1

    if is_pid(state.transport_pid) do
      receive do
        {:codex_transport_frame, pid, _} when pid == state.transport_pid -> :ok
        {:codex_transport_error, pid, _} when pid == state.transport_pid -> :ok
        {:codex_transport_closed, pid, _} when pid == state.transport_pid -> :ok
      after
        0 -> :ok
      end
    end

    %{
      state
      | transport_pid: nil,
        transport_ref: nil,
        reconnect_timer: nil,
        pending_requests: %{},
        connection_generation: new_generation
    }
  end

  # --- Redaction & Safe Projections ---

  defp extract_safe_platform(result) when is_map(result) do
    %{
      platform_family: result["platformFamily"],
      platform_os: result["platformOs"]
    }
  end

  defp extract_safe_platform(_), do: %{}

  defp extract_safe_account(account) when is_map(account) do
    %{
      type: account["type"],
      plan_type: account["planType"],
      auth_mode: account["authMode"]
    }
  end

  defp extract_safe_account(_), do: %{}

  defp call_clock(clock) when is_function(clock, 0), do: clock.()
  defp call_clock(clock) when is_atom(clock), do: clock.now()
  defp call_clock(_), do: DateTime.utc_now()
end
