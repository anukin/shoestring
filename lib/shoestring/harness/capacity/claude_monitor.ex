defmodule Shoestring.Harness.Capacity.ClaudeMonitor do
  @moduledoc """
  Production capacity monitor for Claude Code interactive sessions.

  ## Locked Policy
  Passive, response-driven `statusLine` observation only.
  - Never launches Claude CLI subprocesses to refresh or prompt.
    (Except for an asynchronous version check on startup if version is omitted).
  - Never creates synthetic prompts or consumes model turns.
  - Never runs headless JSON/stream-json modes or scrapes ANSI pixels.
  - Accepts local `statusLine` callbacks delivered via the receiver boundary.

  ## Normalization and Ingestion
  - Normalizes payloads through `Shoestring.Harness.Capacity`.
  - Ingests observations through an injectable sink defaulting to `Shoestring.Harness.Observatory`.
  - Reports `unknown/conservative_partial` before the first usable response
    with reason `"rate_limits_absent_before_first_response_or_unsupported_subscription"`.
  - Missing one window is partial/degraded, never 0%, unlimited, or fully available.
  - Preserves last-known data on parse, schema, transport, or sink failures.
  - Handles concurrent-session uncertainty, duplicates, and out-of-order callbacks deterministically.
  """

  use GenServer

  alias Shoestring.Harness.{
    Capacity,
    CapacitySnapshot,
    Clock,
    Error,
    Observatory,
    SystemClock,
    SystemIdentifier
  }

  alias Shoestring.Harness.Capacity.ClaudeStatusLineReceiver
  alias Shoestring.Trajectory.Redaction

  @behaviour Shoestring.Harness.Capacity.Source

  @default_scope "subscription"
  @default_freshness_seconds 300
  @max_reason_length 300

  defstruct [
    :opts,
    :name,
    :clock,
    :identifier,
    :receiver,
    :sink,
    :version,
    :compatibility,
    :scope,
    :freshness_seconds,
    :status,
    :last_observation,
    :last_observation_scope,
    :last_callback_at,
    :last_captured_at,
    :reason,
    :sink_status,
    :callback_count,
    :sessions
  ]

  # --- Capacity.Source Callbacks ---

  @impl Shoestring.Harness.Capacity.Source
  def provenance do
    %{
      adapter_id: "claude_interactive_status_line",
      provider_id: "claude",
      invocation_mode: "interactive_status_line",
      event: :status_line_input
    }
  end

  @impl Shoestring.Harness.Capacity.Source
  def support_tier, do: :conservative_partial

  @impl Shoestring.Harness.Capacity.Source
  def observe(opts \\ %{}) do
    server = Map.get(opts, :server, __MODULE__)

    case current_snapshot(server, Map.to_list(opts)) do
      {:ok, snapshot} ->
        {:ok, snapshot}

      {:error, reason} ->
        {:error, Error.new(:transport, "claude_observe_failed", to_string(reason))}
    end
  end

  # --- Public Monitor API ---

  @doc """
  Starts the Claude capacity monitor GenServer.

  ## Options
    * `:name` - Registration name (defaults to `__MODULE__`). Pass `nil` for unnamed.
    * `:version` - Normalized CLI version string override (e.g. `"2.1.251"`).
    * `:runner` - Injectable command runner for version discovery (defaults to `SystemCommandRunner`).
    * `:clock` - Injectable clock module or function (defaults to `SystemClock`).
    * `:identifier` - Injectable UUID generator (defaults to `SystemIdentifier`).
    * `:receiver` - Injectable statusLine parser/receiver boundary (defaults to `ClaudeStatusLineReceiver`).
    * `:sink` - Ingestion sink module or function (defaults to `Observatory`).
    * `:scope` - Default scope identifier (defaults to `"subscription"`).
    * `:freshness_seconds` - Observation max age in seconds (defaults to 300).
    * `:auto_ingest_initial` - Ingest pre-first-response snapshot to sink on start (default false).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if is_nil(name), do: [], else: [name: name]
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Accepts a statusLine callback payload, validates through receiver,
  normalizes through Capacity boundary, resolves concurrency/ordering,
  and ingests to sink.
  """
  @spec receive_status_line(GenServer.server(), binary() | map(), keyword()) ::
          {:ok, :persisted | :deduplicated | :out_of_order, CapacitySnapshot.t()}
          | {:error, term()}
  def receive_status_line(server \\ __MODULE__, payload, opts \\ []) do
    GenServer.call(server, {:receive_status_line, payload, opts})
  end

  @doc """
  Returns the current capacity snapshot evaluated against the clock.
  The snapshot is scoped to the provided `:scope` (or the default scope).
  Scope snapshots are never conflated.
  """
  @spec current_snapshot(GenServer.server(), keyword()) ::
          {:ok, CapacitySnapshot.t()} | {:error, term()}
  def current_snapshot(server \\ __MODULE__, opts \\ []) do
    GenServer.call(server, {:current_snapshot, opts})
  end

  @doc """
  Returns comprehensive diagnostic status of the monitor for the provided
  `:scope` (or the default scope).
  """
  @spec status(GenServer.server(), keyword()) :: map()
  def status(server \\ __MODULE__, opts \\ []) do
    GenServer.call(server, {:status, opts})
  end

  @doc """
  Explicitly signals that an interactive session has disconnected.
  Fails closed while preserving the last-known capacity observation for the
  provided `:scope` (or the default scope).
  """
  @spec disconnect(GenServer.server(), String.t(), keyword()) :: {:ok, CapacitySnapshot.t()}
  def disconnect(server \\ __MODULE__, reason \\ "session_disconnected", opts \\ []) do
    GenServer.call(server, {:disconnect, reason, opts})
  end

  @doc """
  Resets monitor to initial pre-first-response state.
  """
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__) do
    GenServer.call(server, :reset)
  end

  # --- GenServer Callbacks ---

  @impl GenServer
  def init(opts) do
    clock = Keyword.get(opts, :clock, SystemClock)
    identifier = Keyword.get(opts, :identifier, SystemIdentifier)
    receiver = Keyword.get(opts, :receiver, ClaudeStatusLineReceiver)
    sink = Keyword.get(opts, :sink, Observatory)
    scope = Keyword.get(opts, :scope, @default_scope)
    freshness_seconds = Keyword.get(opts, :freshness_seconds, @default_freshness_seconds)
    auto_ingest = Keyword.get(opts, :auto_ingest_initial, false)

    now = resolve_now(clock)

    # We delay version discovery if not provided explicitly to avoid blocking init
    {version, compat} =
      case Keyword.get(opts, :version) do
        v when is_binary(v) ->
          norm_v = Capacity.Registry.normalize_version(v)
          {norm_v, Capacity.compatibility(:claude, :interactive_status_line, norm_v)}

        _ ->
          {nil, Capacity.compatibility(:claude, :interactive_status_line, "0.0.0")}
      end

    initial_snapshot = build_initial_snapshot(compat, version, scope, freshness_seconds, now)

    initial_status =
      if compat.compatibility_state == :incompatible, do: :incompatible, else: :ready

    state = %__MODULE__{
      opts: opts,
      name: Keyword.get(opts, :name, __MODULE__),
      clock: clock,
      identifier: identifier,
      receiver: receiver,
      sink: sink,
      version: version,
      compatibility: compat,
      scope: scope,
      freshness_seconds: freshness_seconds,
      status: initial_status,
      last_observation: initial_snapshot,
      last_observation_scope: scope,
      last_callback_at: nil,
      last_captured_at: nil,
      reason: initial_snapshot.reason,
      sink_status: :ok,
      callback_count: 0,
      sessions: %{}
    }

    if auto_ingest do
      _ = safe_ingest(sink, initial_snapshot, now)
    end

    if version == nil do
      {:ok, state, {:continue, :discover_version}}
    else
      {:ok, state}
    end
  end

  @impl GenServer
  def handle_continue(:discover_version, state) do
    now = resolve_now(state.clock)

    version =
      case Capacity.discover_version(:claude, state.opts) do
        {:ok, %{version: v}} -> v
        _ -> nil
      end

    compat = Capacity.compatibility(:claude, :interactive_status_line, version)

    initial_snapshot =
      build_initial_snapshot(compat, version, state.scope, state.freshness_seconds, now)

    initial_status =
      if compat.compatibility_state == :incompatible, do: :incompatible, else: :ready

    new_state = %{
      state
      | version: version,
        compatibility: compat,
        status: initial_status,
        last_observation: initial_snapshot,
        last_observation_scope: state.scope,
        reason: initial_snapshot.reason
    }

    {:noreply, new_state}
  end

  @impl GenServer
  def handle_call({:receive_status_line, payload, call_opts}, _from, state) do
    now = resolve_now(state.clock)

    if state.compatibility.compatibility_state == :incompatible do
      {:reply, {:error, :incompatible_mode}, state}
    else
      do_receive_status_line(payload, call_opts, now, state)
    end
  end

  @impl GenServer
  def handle_call({:current_snapshot, opts}, _from, state) do
    now = Keyword.get(opts, :now) || resolve_now(state.clock)
    scope = Keyword.get(opts, :scope, state.scope)
    snapshot = snapshot_for_scope(state, scope, now)

    evaluated = evaluate_snapshot_freshness(snapshot, now, state.freshness_seconds)
    {:reply, {:ok, evaluated}, state}
  end

  @impl GenServer
  def handle_call({:status, opts}, _from, state) do
    now = resolve_now(state.clock)
    scope = Keyword.get(opts, :scope, state.scope)
    scope_data = scope_data(state, scope)
    scoped? = not is_nil(scope_data.status)

    last_callback_at =
      cond do
        scoped? -> scope_data.last_callback_at
        state.last_observation_scope == scope -> state.last_callback_at
        true -> nil
      end

    callback_age =
      if last_callback_at do
        max(0, DateTime.diff(now, last_callback_at, :second))
      else
        nil
      end

    snapshot = snapshot_for_scope(state, scope, now)
    evaluated_snapshot = evaluate_snapshot_freshness(snapshot, now, state.freshness_seconds)

    scoped_status =
      cond do
        scoped? -> scope_data.status
        state.last_observation_scope == scope -> state.status
        state.compatibility.compatibility_state == :incompatible -> :incompatible
        true -> :ready
      end

    effective_status =
      cond do
        scoped_status in [:refused, :incompatible, :disconnected] ->
          scoped_status

        evaluated_snapshot && evaluated_snapshot.freshness &&
            CapacitySnapshot.freshness(evaluated_snapshot, now) == :stale ->
          :stale

        true ->
          scoped_status
      end

    {reason, sink_status} =
      cond do
        scoped? ->
          {scope_data.reason, scope_data.sink_status}

        state.last_observation_scope == scope ->
          {state.reason, state.sink_status}

        true ->
          {evaluated_snapshot.reason, :ok}
      end

    result = %{
      status: effective_status,
      scope: scope,
      last_observation: evaluated_snapshot,
      last_callback_at: last_callback_at,
      callback_age_seconds: callback_age,
      version: state.version,
      compatibility: state.compatibility,
      reason: reason,
      sink_status: sink_status,
      session_count: map_size(state.sessions),
      callback_count: state.callback_count,
      active_scopes: Map.keys(state.sessions)
    }

    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:disconnect, reason, opts}, _from, state) do
    now = resolve_now(state.clock)
    scope = Keyword.get(opts, :scope, state.scope)
    scope_data = scope_data(state, scope)
    safe_reason = reason |> Redaction.redact() |> bound_reason()
    bounded_reason = bound_reason("session_disconnected: #{safe_reason}")

    last_known =
      last_known_for_scope(scope_data, state, scope) ||
        build_initial_snapshot(
          state.compatibility,
          state.version,
          scope,
          state.freshness_seconds,
          now
        )

    degraded_snapshot =
      case last_known do
        %CapacitySnapshot{} = snapshot ->
          case Capacity.preserve_last_known(snapshot, bounded_reason, now: now) do
            {:ok, preserved} -> preserved
            _ -> snapshot
          end

        _ ->
          last_known
      end

    new_scope_data = %{
      scope_data
      | last_snapshot: degraded_snapshot,
        status: :disconnected,
        reason: bounded_reason
    }

    new_state = %{
      state
      | last_observation: degraded_snapshot,
        last_observation_scope: scope,
        status: :disconnected,
        reason: bounded_reason,
        sessions: Map.put(state.sessions, scope, new_scope_data)
    }

    {:reply, {:ok, degraded_snapshot}, new_state}
  end

  @impl GenServer
  def handle_call(:reset, _from, state) do
    now = resolve_now(state.clock)

    initial_snapshot =
      build_initial_snapshot(
        state.compatibility,
        state.version,
        state.scope,
        state.freshness_seconds,
        now
      )

    new_state = %{
      state
      | status: :ready,
        last_observation: initial_snapshot,
        last_observation_scope: state.scope,
        last_callback_at: nil,
        last_captured_at: nil,
        reason: initial_snapshot.reason,
        sink_status: :ok,
        callback_count: 0,
        sessions: %{}
    }

    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_info(msg, state) do
    require Logger
    Logger.warning("ClaudeMonitor received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # --- Internal Pipeline ---

  defp do_receive_status_line(payload, call_opts, now, state) do
    if is_map(payload) and :erlang.external_size(payload) > 64 * 1024 do
      handle_rejection(
        :payload_oversized,
        "oversized_status_line_payload",
        now,
        call_opts,
        state
      )
    else
      case parse_through_receiver(state.receiver, payload, call_opts) do
        {:error, :payload_oversized} ->
          handle_rejection(
            :payload_oversized,
            "oversized_status_line_payload",
            now,
            call_opts,
            state
          )

        {:error, :contains_secrets_or_forbidden_content} ->
          handle_rejection(
            :contains_secrets_or_forbidden_content,
            "status_line_payload_contains_forbidden_content",
            now,
            call_opts,
            state
          )

        {:error, :malformed_json} ->
          handle_rejection(
            :malformed_json,
            "malformed_json",
            now,
            call_opts,
            state
          )

        {:error, reason} ->
          handle_rejection(
            reason,
            "malformed_payload: #{inspect(reason)}",
            now,
            call_opts,
            state
          )

        {:ok, parsed} ->
          process_parsed_payload(parsed, call_opts, now, state)
      end
    end
  end

  defp process_parsed_payload(parsed, call_opts, now, state) do
    scope = resolve_scope(parsed, call_opts, state.scope)
    session_id = resolve_session_id(parsed, call_opts)
    captured_at = resolve_captured_at(parsed, call_opts, now)

    scope_data = scope_data(state, scope)

    cond do
      # Future timestamp: fails closed
      captured_at != nil and DateTime.compare(captured_at, now) == :gt ->
        handle_future_timestamp(parsed, scope, captured_at, now, state)

      # Duplicate callback check
      duplicate_callback?(captured_at, parsed, scope_data) ->
        duplicate_snap =
          last_known_for_scope(scope_data, state, scope) ||
            snapshot_for_scope(state, scope, now)

        {:reply, {:ok, :deduplicated, duplicate_snap}, state}

      # Out-of-order callback check
      out_of_order_callback?(captured_at, scope_data) ->
        current_snap =
          last_known_for_scope(scope_data, state, scope) ||
            snapshot_for_scope(state, scope, now)

        {:reply, {:ok, :out_of_order, current_snap}, state}

      true ->
        normalize_and_ingest(parsed, scope, session_id, captured_at, now, scope_data, state)
    end
  end

  defp normalize_and_ingest(parsed, scope, session_id, captured_at, now, scope_data, state) do
    last_known = last_known_for_scope(scope_data, state, scope)

    norm_opts = [
      version: state.version,
      now: now,
      captured_at: captured_at,
      scope: scope,
      freshness_seconds: state.freshness_seconds,
      last_known_snapshot: last_known,
      source_event: :status_line_input
    ]

    case Capacity.normalize(:claude, :interactive_status_line, parsed, norm_opts) do
      {:ok, snapshot} ->
        {conserved_snapshot, updated_active_sessions} =
          apply_concurrency_policy(
            snapshot,
            scope_data.active_sessions,
            session_id,
            captured_at,
            state.freshness_seconds,
            now
          )

        case safe_ingest(state.sink, conserved_snapshot, now) do
          {:ok, ingest_status, final_snapshot} ->
            new_status =
              case final_snapshot.capacity_state do
                :refused -> :refused
                :degraded -> :degraded
                :unknown -> :unknown
                :observed -> :observed
              end

            new_scope_data = %{
              scope_data
              | last_captured_at: captured_at,
                last_snapshot: final_snapshot,
                active_sessions: updated_active_sessions,
                last_callback_at: now,
                status: new_status,
                reason: final_snapshot.reason,
                sink_status: :ok
            }

            new_sessions = Map.put(state.sessions, scope, new_scope_data)

            new_state = %{
              state
              | last_observation: final_snapshot,
                last_observation_scope: scope,
                last_callback_at: now,
                last_captured_at: captured_at,
                status: new_status,
                reason: final_snapshot.reason,
                sink_status: :ok,
                callback_count: state.callback_count + 1,
                sessions: new_sessions
            }

            {:reply, {:ok, ingest_status, final_snapshot}, new_state}

          {:error, sink_error} ->
            # Sink failure: fail closed while preserving last-known data
            bounded_sink_reason = bound_reason("sink_failure: #{inspect(sink_error)}")

            degraded_snapshot =
              case last_known do
                %CapacitySnapshot{} = lk ->
                  case Capacity.preserve_last_known(lk, bounded_sink_reason, now: now) do
                    {:ok, preserved} -> preserved
                    _ -> conserved_snapshot
                  end

                _ ->
                  conserved_snapshot
              end

            new_scope_data = %{
              scope_data
              | last_snapshot: degraded_snapshot,
                status: :degraded,
                reason: bounded_sink_reason,
                sink_status: {:error, sink_error}
            }

            new_state = %{
              state
              | last_observation: degraded_snapshot,
                last_observation_scope: scope,
                status: :degraded,
                reason: bounded_sink_reason,
                sink_status: {:error, sink_error},
                callback_count: state.callback_count + 1,
                sessions: Map.put(state.sessions, scope, new_scope_data)
            }

            {:reply, {:error, {:sink_failure, sink_error}}, new_state}
        end

      {:error, norm_error} ->
        bounded_error_reason = bound_reason("normalization_error: #{inspect(norm_error)}")

        degraded_snapshot =
          case last_known do
            %CapacitySnapshot{} = lk ->
              case Capacity.preserve_last_known(lk, bounded_error_reason, now: now) do
                {:ok, preserved} -> preserved
                _ -> lk
              end

            _ ->
              build_initial_snapshot(
                state.compatibility,
                state.version,
                scope,
                state.freshness_seconds,
                now
              )
              |> Map.put(:capacity_state, :degraded)
              |> Map.put(:reason, bounded_error_reason)
          end

        new_scope_data = %{
          scope_data
          | last_snapshot: degraded_snapshot,
            status: :degraded,
            reason: bounded_error_reason
        }

        new_state = %{
          state
          | last_observation: degraded_snapshot,
            last_observation_scope: scope,
            status: :degraded,
            reason: bounded_error_reason,
            callback_count: state.callback_count + 1,
            sessions: Map.put(state.sessions, scope, new_scope_data)
        }

        {:reply, {:error, norm_error}, new_state}
    end
  end

  defp handle_future_timestamp(parsed, scope, captured_at, now, state) do
    scope_data = scope_data(state, scope)
    last_known = last_known_for_scope(scope_data, state, scope)

    bounded_reason = bound_reason("missing_or_invalid_observation_timestamp")

    degraded_snapshot =
      case last_known do
        %CapacitySnapshot{} = lk ->
          case Capacity.preserve_last_known(lk, bounded_reason, now: now) do
            {:ok, preserved} -> preserved
            _ -> lk
          end

        _ ->
          Capacity.normalize(
            :claude,
            :interactive_status_line,
            parsed,
            version: state.version,
            now: now,
            captured_at: captured_at,
            scope: scope,
            freshness_seconds: state.freshness_seconds
          )
          |> elem(1)
      end

    new_scope_data = %{
      scope_data
      | last_snapshot: degraded_snapshot,
        last_callback_at: now,
        status: degraded_snapshot.capacity_state,
        reason: degraded_snapshot.reason
    }

    new_state = %{
      state
      | last_observation: degraded_snapshot,
        last_observation_scope: scope,
        last_callback_at: now,
        status: degraded_snapshot.capacity_state,
        reason: degraded_snapshot.reason,
        callback_count: state.callback_count + 1,
        sessions: Map.put(state.sessions, scope, new_scope_data)
    }

    {:reply, {:ok, :persisted, degraded_snapshot}, new_state}
  end

  defp handle_rejection(error_tag, diagnostic_reason, now, call_opts, state) do
    bounded = bound_reason(diagnostic_reason)
    scope = Keyword.get(call_opts, :scope, state.scope)
    scope_data = scope_data(state, scope)
    last_known = last_known_for_scope(scope_data, state, scope)

    degraded_snapshot =
      case last_known do
        %CapacitySnapshot{} = lk ->
          case Capacity.preserve_last_known(lk, bounded, now: now) do
            {:ok, preserved} -> preserved
            _ -> lk
          end

        _ ->
          build_initial_snapshot(
            state.compatibility,
            state.version,
            scope,
            state.freshness_seconds,
            now
          )
          |> Map.put(:capacity_state, :degraded)
          |> Map.put(:reason, bounded)
      end

    new_scope_data = %{
      scope_data
      | last_snapshot: degraded_snapshot,
        status: :degraded,
        reason: bounded
    }

    new_state = %{
      state
      | last_observation: degraded_snapshot,
        last_observation_scope: scope,
        status: :degraded,
        reason: bounded,
        callback_count: state.callback_count + 1,
        sessions: Map.put(state.sessions, scope, new_scope_data)
    }

    {:reply, {:error, error_tag}, new_state}
  end

  # --- Concurrency Policy ---

  defp apply_concurrency_policy(
         snapshot,
         active_sessions,
         session_id,
         captured_at,
         freshness_seconds,
         now
       ) do
    # Prune inactive sessions older than freshness window
    pruned =
      Enum.reject(active_sessions, fn {_id, entry} ->
        entry[:last_seen] && DateTime.diff(now, entry[:last_seen], :second) > freshness_seconds
      end)
      |> Map.new()

    # Check for divergent concurrent session observations
    divergent? =
      Enum.any?(pruned, fn {other_id, entry} ->
        other_id != session_id and
          divergent_windows?(snapshot.windows, entry[:windows])
      end)

    updated_sessions =
      Map.put(pruned, session_id, %{
        last_seen: captured_at || now,
        windows: snapshot.windows
      })

    # Confidence must never be elevated beyond evidence:
    # Claude is conservative_partial; if concurrent sessions diverge, downgrade to low.
    final_snapshot =
      cond do
        divergent? ->
          reason = bound_reason("#{snapshot.reason || "observed"}; concurrent_session_divergence")

          %{
            snapshot
            | confidence: :low,
              capacity_state: :degraded,
              reason: reason
          }

        snapshot.confidence == :high ->
          # Claude observations never exceed medium confidence
          %{snapshot | confidence: :medium}

        true ->
          snapshot
      end

    {final_snapshot, updated_sessions}
  end

  defp divergent_windows?(windows_a, windows_b)
       when is_list(windows_a) and is_list(windows_b) do
    Enum.any?(windows_a, fn wa ->
      case Enum.find(windows_b, &(&1.kind == wa.kind)) do
        nil ->
          false

        wb ->
          wa.state == :observed and wb.state == :observed and
            wa.used_percent != nil and wb.used_percent != nil and
            abs(wa.used_percent - wb.used_percent) > 0.01
      end
    end)
  end

  defp divergent_windows?(_a, _b), do: false

  # --- Deduplication and Ordering Helpers ---

  defp duplicate_callback?(captured_at, parsed, scope_data) do
    captured_at != nil and
      scope_data.last_captured_at != nil and
      DateTime.compare(captured_at, scope_data.last_captured_at) == :eq and
      windows_equivalent_to_parsed?(scope_data.last_snapshot, parsed)
  end

  defp windows_equivalent_to_parsed?(%CapacitySnapshot{windows: windows}, parsed)
       when is_map(parsed) do
    rate_limits = Map.get(parsed, "rate_limits")

    case rate_limits do
      nil ->
        windows == [] or Enum.all?(windows, &(&1.state == :unknown))

      %{} ->
        five_hour = Map.get(rate_limits, "five_hour")
        seven_day = Map.get(rate_limits, "seven_day")

        w_5 = Enum.find(windows, &(&1.kind == "five_hour"))
        w_7 = Enum.find(windows, &(&1.kind == "seven_day"))

        window_matches?(w_5, five_hour) and window_matches?(w_7, seven_day)

      _ ->
        false
    end
  end

  defp windows_equivalent_to_parsed?(_snapshot, _parsed), do: false

  defp window_matches?(nil, nil), do: true
  defp window_matches?(%{state: :unknown}, nil), do: true

  defp window_matches?(%{state: :observed, used_percent: used}, %{
         "used_percentage" => parsed_used
       }) do
    used == parsed_used
  end

  defp window_matches?(_w, _p), do: false

  defp out_of_order_callback?(captured_at, scope_data) do
    captured_at != nil and
      scope_data.last_captured_at != nil and
      DateTime.compare(captured_at, scope_data.last_captured_at) == :lt
  end

  # --- Receiver and Ingestion Boundaries ---

  defp parse_through_receiver(receiver, payload, opts) do
    cond do
      is_atom(receiver) ->
        receiver.parse(payload, opts)

      is_function(receiver, 2) ->
        receiver.(payload, opts)

      is_function(receiver, 1) ->
        receiver.(payload)

      true ->
        {:error, :invalid_receiver}
    end
  end

  defp safe_ingest(sink, %CapacitySnapshot{} = snapshot, now) do
    task =
      Task.async(fn ->
        receive do
          :invoke_sink ->
            try do
              cond do
                is_atom(sink) ->
                  sink.ingest(snapshot, now: now)

                is_function(sink, 2) ->
                  sink.(snapshot, now: now)

                is_function(sink, 1) ->
                  sink.(snapshot)

                true ->
                  {:error, :invalid_sink}
              end
            rescue
              e -> {:error, e}
            catch
              _kind, reason -> {:error, reason}
            end
        end
      end)

    Process.unlink(task.pid)
    send(task.pid, :invoke_sink)

    # A timed-out sink may already have committed before shutdown completes. Observatory
    # retries are idempotent by snapshot ID; injected sinks must provide the same guarantee.
    case Task.yield(task, 3000) || Task.shutdown(task) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, reason}
      nil -> {:error, :timeout}
    end
  end

  # --- Freshness and State Helpers ---

  defp evaluate_snapshot_freshness(nil, _now, _freshness_seconds), do: nil

  defp evaluate_snapshot_freshness(%CapacitySnapshot{} = snapshot, now, freshness_seconds) do
    if snapshot.observed_at do
      is_stale = DateTime.diff(now, snapshot.observed_at, :second) > freshness_seconds

      if is_stale and snapshot.capacity_state in [:observed, :degraded] do
        new_reason =
          if snapshot.reason && String.contains?(snapshot.reason, "stale_observation") do
            snapshot.reason
          else
            bound_reason(
              [snapshot.reason, "stale_observation"]
              |> Enum.reject(&is_nil/1)
              |> Enum.join("; ")
            )
          end

        %{
          snapshot
          | capacity_state: :degraded,
            confidence: :low,
            reason: new_reason
        }
      else
        snapshot
      end
    else
      snapshot
    end
  end

  defp build_initial_snapshot(_compat, version, scope, freshness_seconds, now) do
    {:ok, snapshot} =
      Capacity.normalize(
        :claude,
        :interactive_status_line,
        %{"payload" => %{}},
        version: version,
        now: now,
        scope: scope,
        freshness_seconds: freshness_seconds
      )

    snapshot
  end

  defp scope_data(state, scope) do
    Map.get(state.sessions, scope, %{
      last_captured_at: nil,
      last_snapshot: nil,
      active_sessions: %{},
      last_callback_at: nil,
      status: nil,
      reason: nil,
      sink_status: :ok
    })
  end

  defp last_known_for_scope(scope_data, state, scope) do
    scope_data.last_snapshot ||
      if state.last_observation_scope == scope do
        state.last_observation
      else
        nil
      end
  end

  defp snapshot_for_scope(state, scope, now) do
    scope_data = scope_data(state, scope)

    last_known_for_scope(scope_data, state, scope) ||
      build_initial_snapshot(
        state.compatibility,
        state.version,
        scope,
        state.freshness_seconds,
        now
      )
  end

  defp resolve_scope(parsed, opts, default_scope) do
    Keyword.get(opts, :scope) ||
      Map.get(parsed, "scope") ||
      default_scope
  end

  defp resolve_session_id(parsed, opts) do
    Keyword.get(opts, :session_id) ||
      Map.get(parsed, "session_id") ||
      "default"
  end

  defp resolve_captured_at(parsed, opts, _fallback_now) do
    case Keyword.get(opts, :captured_at) || Keyword.get(opts, :observed_at) do
      %DateTime{} = dt ->
        dt

      iso when is_binary(iso) ->
        case DateTime.from_iso8601(iso) do
          {:ok, dt, _} -> dt
          _ -> nil
        end

      nil ->
        str = Map.get(parsed, "captured_at") || Map.get(parsed, "observed_at")

        if is_binary(str) do
          case DateTime.from_iso8601(str) do
            {:ok, dt, _} -> dt
            _ -> nil
          end
        else
          nil
        end
    end
  end

  defp resolve_now(clock) do
    case clock do
      %DateTime{} = dt ->
        dt

      mod when is_atom(mod) ->
        Clock.now(mod)

      fun when is_function(fun, 0) ->
        fun.()

      _ ->
        DateTime.utc_now()
    end
  end

  defp bound_reason(nil), do: nil

  defp bound_reason(reason) when is_binary(reason) do
    String.slice(reason, 0, @max_reason_length)
  end
end
