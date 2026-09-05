defmodule Shoestring.Elves.Elf do
  @moduledoc """
  A GenServer supervising one bounded external harness run.

  One Elf owns one run: it reconciles durable trajectory/run state before
  spawning anything (so an Oban retry can never blindly duplicate an uncertain
  external effect), launches the OS process group through
  `Shoestring.Elves.PortRunner`, streams normalized adapter events live into
  the trajectory (validated, reasoning-stripped, redacted, bounded), and
  reports exactly one idempotent terminal state classified by
  `Shoestring.Elves.Classifier`.

  ## Durable-first ordering

    1. `dispatch.requested` / run intent must already exist — the Elf verifies
       the canonical `dispatch.requested` event and stops fail-closed when it
       is missing. Intent is persisted by `Shoestring.Elves.start_run/3`
       (via `Shoestring.Harness.Dispatches.enqueue/3`) before the Elf starts,
       or by the Oban `DispatchWorker` path before the effect runs.
    2. A stable `Registry` entry per `run_id` plus a durable terminal check
       make duplicate starts converge instead of duplicating work.
    3. An already-live process group (left behind by a crash or restart) is
       adopted, never re-spawned: the new Elf supervises the orphan to an
       explicit terminal instead of launching a second effect.

  ## Bounds (fail-closed)

    * `max_events_per_run:` (default 1 000) — more adapter events fail the run
      with `log_overflow` instead of flooding the trajectory and PubSub.
    * `max_event_bytes:` (default 32 768) — any single normalized payload past
      the cap fails the run explicitly; oversized output is never truncated
      silently.
    * `max_output_bytes:` (default `PortRunner.default_max_output_bytes/0`) —
      raw OS output past the cap fails the run explicitly.
    * The persisted log artifact is bounded by the same output cap and marked
      redacted; PubSub/UI fan-out is bounded because every broadcast
      corresponds to one bounded persisted event.

  ## What this Elf does not do

  It never auto-kills on quiet heartbeats (see `Shoestring.Elves.Staleness`),
  never synthesizes semantic completions, and never launches a replacement —
  replacement requires an explicit terminal or reconciliation first.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias Shoestring.Elves.{Classifier, PortRunner}
  alias Shoestring.Harness.{Clock, HarnessEvent}
  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{ArtifactStore, Redaction, TrajectoryEvent}

  @default_max_events_per_run 1_000
  @default_max_event_bytes 32_768
  @default_event_interval_ms 0
  @default_orphan_poll_ms 100

  @hidden_extension_pattern ~r/(?i)(reasoning|thinking|chain_of_thought|scratchpad|system_prompt|raw_transcript|hidden)/

  @type t :: %__MODULE__{
          goal_id: Ecto.UUID.t(),
          run_id: Ecto.UUID.t(),
          task_id: Ecto.UUID.t(),
          dispatch_id: Ecto.UUID.t(),
          request: map(),
          adapter: module(),
          adapter_opts: map(),
          command: [binary()],
          env: [{binary(), binary()}],
          runner_opts: keyword(),
          event_interval_ms: non_neg_integer(),
          max_events_per_run: pos_integer(),
          max_event_bytes: pos_integer(),
          clock: module(),
          repo: module(),
          notify: pid() | nil,
          orphan_poll_ms: pos_integer(),
          runner: PortRunner.t() | nil,
          adopted_pgid: pos_integer() | nil,
          pending_events: [HarnessEvent.t()],
          events_overflow?: boolean(),
          adapter_verdict: term(),
          os_exit: term(),
          cancel_requested?: boolean(),
          terminal: map() | nil,
          seen: MapSet.t(String.t()),
          event_count: non_neg_integer(),
          provider_session_id: String.t() | nil,
          os_buffer: binary(),
          output_overflowed?: boolean()
        }

  defstruct [
    :goal_id,
    :run_id,
    :task_id,
    :dispatch_id,
    :request,
    :adapter,
    :adapter_opts,
    :command,
    :env,
    :runner_opts,
    :event_interval_ms,
    :max_events_per_run,
    :max_event_bytes,
    :clock,
    :repo,
    :notify,
    :orphan_poll_ms,
    :runner,
    :adopted_pgid,
    pending_events: [],
    events_overflow?: false,
    adapter_verdict: :none,
    os_exit: :unknown,
    cancel_requested?: false,
    terminal: nil,
    seen: nil,
    event_count: 0,
    provider_session_id: nil,
    os_buffer: "",
    output_overflowed?: false
  ]

  @doc """
  Starts one Elf for `run_id`. Returns `{:error, {:already_started, pid}}`
  when an Elf for the run is already alive — callers must use the existing
  one instead of duplicating the effect.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    GenServer.start_link(__MODULE__, opts, name: via(run_id))
  end

  @doc false
  @spec via(Ecto.UUID.t()) :: {:via, Registry, {module(), Ecto.UUID.t()}}
  def via(run_id), do: {:via, Registry, {Shoestring.Elves.Registry, run_id}}

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    run_id = Keyword.fetch!(opts, :run_id)

    %{
      id: {__MODULE__, run_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc "Requests cancellation: terminates the owned process group, then reports cancelled."
  @spec cancel(GenServer.server(), keyword()) ::
          {:ok, :cancelled | :already_terminal} | {:error, term()}
  def cancel(server, opts \\ []) do
    GenServer.call(server, {:cancel, opts}, Keyword.get(opts, :timeout, 30_000))
  end

  @impl GenServer
  def init(opts) do
    state = %__MODULE__{
      goal_id: Keyword.fetch!(opts, :goal_id),
      run_id: Keyword.fetch!(opts, :run_id),
      task_id: Keyword.fetch!(opts, :task_id),
      dispatch_id: Keyword.fetch!(opts, :dispatch_id),
      request: Keyword.fetch!(opts, :request),
      adapter: Keyword.get(opts, :adapter, Shoestring.Harness.Fake),
      adapter_opts: Keyword.get(opts, :adapter_opts, %{}),
      command: Keyword.get(opts, :command, ["sleep", "30"]),
      env: Keyword.get(opts, :env, []),
      runner_opts: Keyword.get(opts, :runner_opts, []),
      event_interval_ms: Keyword.get(opts, :event_interval_ms, @default_event_interval_ms),
      max_events_per_run: Keyword.get(opts, :max_events_per_run, @default_max_events_per_run),
      max_event_bytes: Keyword.get(opts, :max_event_bytes, @default_max_event_bytes),
      clock: Keyword.get(opts, :clock, Shoestring.Harness.SystemClock),
      repo: Keyword.get(opts, :repo, Repo),
      notify: Keyword.get(opts, :notify),
      orphan_poll_ms: Keyword.get(opts, :orphan_poll_ms, @default_orphan_poll_ms),
      adopted_pgid: Keyword.get(opts, :adopt_pgid),
      seen: MapSet.new()
    }

    {:ok, state, {:continue, :launch}}
  end

  @impl GenServer
  def handle_continue(:launch, state) do
    try do
      case reconcile_before_spawn(state) do
        {:stop, reason, state} -> {:stop, reason, state}
        {:adopt, state} -> adopt_group(state)
        {:fresh, state} -> launch_fresh(state)
      end
    rescue
      _error -> crash_land(state)
    catch
      _kind, _reason -> crash_land(state)
    end
  end

  @impl GenServer
  def handle_continue(:next_event, state) do
    consume_next_event(state)
  end

  @impl GenServer
  def handle_call({:cancel, _opts}, _from, state) do
    if state.terminal != nil do
      {:reply, {:ok, :already_terminal}, state}
    else
      state = %{state | cancel_requested?: true}
      _ = append_cancelling(state)
      _ = terminate_owned_group(state)

      case commit_terminal(state, Classifier.classify(:no_verdict, state.os_exit, true)) do
        {:duplicate, state} -> {:reply, {:ok, :already_terminal}, state}
        {:terminal, state} -> {:stop, :normal, {:ok, :cancelled}, state}
      end
    end
  end

  @impl GenServer
  def handle_info({port, {:data, bytes}}, state) when is_port(port) do
    handle_os_data(state, bytes)
  end

  @impl GenServer
  def handle_info({port, {:exit_status, status}}, state)
      when is_port(port) and is_integer(status) do
    handle_os_exit(state, status)
  end

  @impl GenServer
  def handle_info(:next_event, state) do
    consume_next_event(state)
  end

  @impl GenServer
  def handle_info(:poll_orphan, state) do
    if state.terminal != nil do
      {:noreply, state}
    else
      pgid = owned_pgid(state)

      if pgid != nil and PortRunner.alive_id?(pgid) do
        Process.send_after(self(), :poll_orphan, state.orphan_poll_ms)
        {:noreply, state}
      else
        finish_after_stream(%{state | os_exit: :unknown})
      end
    end
  end

  @impl GenServer
  def terminate(reason, state) do
    # Best-effort crash marker: recovery (`Shoestring.Elves.reconcile/2`) is
    # the authority and re-derives the terminal if this append cannot land
    # (e.g. mid-shutdown). Never raises out of terminate.
    if state.terminal == nil and reason not in [:normal, :shutdown, {:shutdown, :intent_missing}] do
      try do
        append_terminal_event(state, Classifier.supervisor_crash())
      rescue
        _error -> :ok
      catch
        _kind, _reason -> :ok
      end
    else
      :ok
    end
  end

  # -- Launch --

  defp reconcile_before_spawn(state) do
    cond do
      terminal_recorded?(state) ->
        {:stop, :normal, %{state | terminal: read_terminal(state)}}

      not intent_persisted?(state) ->
        {:stop, {:shutdown, :intent_missing}, state}

      state.adopted_pgid != nil ->
        {:adopt, state}

      true ->
        case live_group(state) do
          nil -> {:fresh, restore_stream_position(state)}
          pgid -> {:adopt, %{state | adopted_pgid: pgid}}
        end
    end
  end

  defp intent_persisted?(state) do
    state.repo.exists?(
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^state.goal_id and event.run_id == ^state.run_id and
            event.type == "dispatch.requested" and
            event.idempotency_key == ^"dispatch-requested:#{state.dispatch_id}"
    )
  end

  defp terminal_recorded?(state) do
    state.repo.exists?(
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^state.goal_id and event.run_id == ^state.run_id and
            event.type in ["run.completed", "run.failed", "run.interrupted", "run.cancelled"]
    )
  end

  defp read_terminal(state) do
    query =
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^state.goal_id and event.run_id == ^state.run_id and
            event.type in ["run.completed", "run.failed", "run.interrupted", "run.cancelled"],
        order_by: [desc: event.sequence],
        limit: 1

    case state.repo.one(query) do
      %TrajectoryEvent{type: "run.completed"} ->
        %{class: :completed}

      %TrajectoryEvent{type: "run.interrupted"} ->
        %{class: :interrupted}

      %TrajectoryEvent{type: "run.cancelled"} ->
        %{class: :cancelled}

      %TrajectoryEvent{type: "run.failed", payload: payload} ->
        %{class: :failed, payload: payload}

      nil ->
        nil
    end
  end

  defp live_group(state) do
    query =
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^state.goal_id and event.run_id == ^state.run_id and
            event.type == "run.running",
        order_by: [desc: event.sequence],
        limit: 1,
        select: event.payload

    case state.repo.one(query) do
      %{"process_id" => process_id} ->
        case parse_pgid(process_id) do
          nil -> nil
          pgid -> if PortRunner.alive_id?(pgid), do: pgid, else: nil
        end

      _other ->
        nil
    end
  end

  defp parse_pgid("pgid:" <> rest) do
    case Integer.parse(rest) do
      {pgid, _rest} when pgid > 1 -> pgid
      _other -> nil
    end
  end

  defp parse_pgid(process_id) when is_binary(process_id) do
    case Integer.parse(process_id) do
      {pgid, _rest} when pgid > 1 -> pgid
      _other -> nil
    end
  end

  defp parse_pgid(_process_id), do: nil

  defp rebuild_seen(state) do
    keys =
      state.repo.all(
        from event in TrajectoryEvent,
          where:
            event.goal_id == ^state.goal_id and event.run_id == ^state.run_id and
              event.type == "harness.event_recorded" and not is_nil(event.idempotency_key),
          select: event.idempotency_key
      )

    %{state | seen: MapSet.new(keys)}
  end

  # A retry after a crash re-streams from the start but must not duplicate
  # logical transitions: already-persisted transport events are skipped via
  # the restored seen-set, and an already-recorded adapter verdict is reused
  # instead of waiting for a second delivery.
  defp restore_stream_position(state) do
    state |> rebuild_seen() |> Map.put(:adapter_verdict, recorded_verdict(state))
  end

  defp recorded_verdict(state) do
    query =
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^state.goal_id and event.run_id == ^state.run_id and
            event.type == "harness.event_recorded",
        order_by: [desc: event.sequence]

    query
    |> state.repo.all()
    |> Enum.find_value(:none, fn
      %TrajectoryEvent{payload: %{"kind" => "result", "result" => %{"status" => status}}} ->
        {:result, status}

      %TrajectoryEvent{payload: %{"kind" => "error", "error" => error}} when is_map(error) ->
        {:error, error}

      _event ->
        false
    end)
  end

  defp adopt_group(state) do
    state = rebuild_seen(%{state | adapter_verdict: recorded_verdict(state)})
    Process.send_after(self(), :poll_orphan, state.orphan_poll_ms)
    {:noreply, state}
  end

  defp launch_fresh(state) do
    with :ok <- append_starting(state),
         {:ok, identity} <- start_adapter(state),
         {:ok, runner} <- spawn_group(state) do
      state = %{state | runner: runner, provider_session_id: identity.provider_session_id}

      case append_running(state) do
        :ok -> begin_streaming(state)
        {:error, reason} -> abort_launch(state, Classifier.launch_failed(), reason)
      end
    else
      {:error, %Shoestring.Harness.Error{} = error} ->
        abort_launch(state, Classifier.classify({:error, error}, :unknown, false), error.code)

      {:error, reason} ->
        abort_launch(state, Classifier.launch_failed(launch_code(reason)), reason)
    end
  end

  # Launch failures persist their concrete cause (`setsid_unavailable`,
  # `executable_not_found`, ...) instead of an opaque default, so an operator
  # on a minimal host can diagnose the run from the trajectory alone.
  defp launch_code(:setsid_unavailable), do: "setsid_unavailable"
  defp launch_code({:executable_not_found, _exe}), do: "executable_not_found"
  defp launch_code({:port_open_failed, _reason}), do: "port_open_failed"
  defp launch_code(:os_pid_unavailable), do: "os_pid_unavailable"
  defp launch_code(:not_group_leader), do: "not_group_leader"
  defp launch_code(:group_leader_unverifiable), do: "group_leader_unverifiable"
  defp launch_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp launch_code(reason) when is_binary(reason), do: reason
  defp launch_code(_reason), do: "process_launch_failed"

  defp abort_launch(state, terminal, _reason) do
    _ = terminate_owned_group(state)
    stop_with_terminal(state, terminal)
  end

  # An unexpected exception during launch (e.g. a misconfigured adapter
  # raising instead of returning `{:error, _}`) still lands exactly one
  # explicit terminal rather than dying silently.
  defp crash_land(state) do
    _ =
      try do
        append_terminal_event(state, Classifier.launch_failed("elf_launch_crashed"))
      rescue
        _error -> :ok
      catch
        _kind, _reason -> :ok
      end

    {:stop, :normal, %{state | terminal: Classifier.launch_failed("elf_launch_crashed")}}
  end

  defp append_starting(state) do
    append_run_event(state, "run.starting", %{"run_id" => state.run_id}, "elf-starting:")
  end

  defp append_running(state) do
    pgid = state.runner.pgid

    append_run_event(
      state,
      "run.running",
      %{
        "run_id" => state.run_id,
        "provider_session_id" => state.provider_session_id,
        "process_id" => "pgid:#{pgid}"
      },
      "elf-running:"
    )
  end

  defp append_cancelling(state) do
    append_run_event(state, "run.cancelling", %{"run_id" => state.run_id}, "elf-cancelling:")
  end

  defp append_run_event(state, type, payload, key_prefix) do
    attrs = %{
      "type" => type,
      "schema_version" => 1,
      "actor" => "elf",
      "occurred_at" => Clock.now(state.clock),
      "idempotency_key" => "#{key_prefix}#{state.dispatch_id}",
      "payload" => payload
    }

    case Trajectory.append(state.goal_id, attrs,
           trusted: [task_id: state.task_id, run_id: state.run_id]
         ) do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_adapter(state) do
    adapter_opts = Map.merge(%{clock: state.clock}, state.adapter_opts)
    state.adapter.start(state.request, adapter_opts)
  end

  defp spawn_group(state) do
    PortRunner.spawn(state.command, [env: state.env] ++ state.runner_opts)
  end

  defp begin_streaming(state) do
    case materialize_stream(state) do
      {:ok, events} ->
        schedule_next(%{state | pending_events: events})

      {:overflow, events} ->
        schedule_next(%{state | pending_events: events, events_overflow?: true})

      {:error, reason} ->
        abort_launch(state, Classifier.launch_failed(), reason)
    end
  end

  defp materialize_stream(state) do
    adapter_opts = Map.merge(%{clock: state.clock}, state.adapter_opts)

    identity = %Shoestring.Harness.RunIdentity{
      run_id: state.run_id,
      harness_id: "elf",
      process_id: nil,
      provider_session_id: state.provider_session_id
    }

    case state.adapter.stream(identity, adapter_opts) do
      {:ok, enumerable} ->
        capped = Enum.take(enumerable, state.max_events_per_run + 1)

        if length(capped) > state.max_events_per_run do
          {:overflow, Enum.take(capped, state.max_events_per_run)}
        else
          {:ok, capped}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp schedule_next(state) do
    if state.event_interval_ms > 0 do
      Process.send_after(self(), :next_event, state.event_interval_ms)
      {:noreply, state}
    else
      {:noreply, state, {:continue, :next_event}}
    end
  end

  # -- Event consumption --

  defp consume_next_event(state) do
    cond do
      state.terminal != nil ->
        {:noreply, state}

      state.events_overflow? ->
        overflow_shutdown(state)

      true ->
        case state.pending_events do
          [] -> finish_after_stream(state)
          [event | rest] -> ingest_event(%{state | pending_events: rest}, event)
        end
    end
  end

  defp ingest_event(state, %HarnessEvent{} = event) do
    # The adapter-assigned `source_event_id` is the stable logical identity;
    # the ordinal is a transport ordering hint (transports may redeliver or
    # reorder), so it is deliberately not part of the idempotency key.
    key = "elf-event:#{state.dispatch_id}:#{event.source_event_id}"

    if MapSet.member?(state.seen, key) do
      # Duplicate transport delivery: no duplicate logical transition.
      schedule_next(state)
    else
      case persist_normalized_event(state, event, key) do
        {:ok, :persisted, state} -> after_ingest(state, event, key)
        {:ok, :duplicate, state} -> schedule_next(%{state | seen: MapSet.put(state.seen, key)})
        {:overflow, state} -> overflow_shutdown(state)
        {:error, reason, state} -> drop_with_warning(state, event, key, reason)
      end
    end
  end

  # The provider offers no backfill, so a dropped event is a permanent hole:
  # never skip silently — log the identity and cause, then continue with the
  # stream rather than failing a run that may still be doing useful work.
  defp drop_with_warning(state, event, key, reason) do
    Logger.warning("elf dropped harness event",
      run_id: state.run_id,
      dispatch_id: state.dispatch_id,
      event_key: key,
      event_kind: event.kind,
      event_ordinal: event.ordinal,
      reason: inspect(reason)
    )

    schedule_next(state)
  end

  defp after_ingest(state, event, key) do
    state = %{state | seen: MapSet.put(state.seen, key), event_count: state.event_count + 1}

    case verdict_of(event) do
      :none ->
        schedule_next(state)

      verdict ->
        state = %{state | adapter_verdict: verdict}
        _ = terminate_owned_group(state)

        stop_with_terminal(
          state,
          Classifier.classify(verdict, state.os_exit, state.cancel_requested?)
        )
    end
  end

  defp verdict_of(%HarnessEvent{kind: :result, result: %{status: status}})
       when is_binary(status) do
    {:result, status}
  end

  defp verdict_of(%HarnessEvent{kind: :error, error: %Shoestring.Harness.Error{} = error}) do
    {:error, error}
  end

  defp verdict_of(_event), do: :none

  defp persist_normalized_event(state, event, key) do
    payload = normalized_payload(state, event)

    with :ok <- check_event_bytes(state, payload) do
      attrs = %{
        "type" => "harness.event_recorded",
        "schema_version" => 1,
        "actor" => "elf",
        "occurred_at" => event.occurred_at,
        "idempotency_key" => key,
        "payload" => payload
      }

      append_opts = [trusted: [task_id: state.task_id, run_id: state.run_id]]

      if state.repo.exists?(
           from e in TrajectoryEvent,
             where: e.goal_id == ^state.goal_id and e.idempotency_key == ^key
         ) do
        {:ok, :duplicate, state}
      else
        case Trajectory.append(state.goal_id, attrs, append_opts) do
          {:ok, _event} -> {:ok, :persisted, state}
          {:error, _reason} = error -> {:error, error, state}
        end
      end
    else
      {:error, :event_overflow} -> {:overflow, state}
    end
  end

  defp normalized_payload(state, event) do
    %{
      "run_id" => state.run_id,
      "source_event_id" => event.source_event_id,
      "ordinal" => event.ordinal,
      "occurred_at" => DateTime.to_iso8601(event.occurred_at),
      "kind" => Atom.to_string(event.kind),
      "process_id" => process_label(state),
      "provider_session_id" => event.provider_session_id || state.provider_session_id,
      "artifact_id" => event.artifact_id,
      "capacity_snapshot_id" => event.capacity_snapshot_id,
      "error" => error_payload(event.error),
      "result" => result_payload(event.result),
      "extensions" => sanitize_extensions(event.extensions)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp process_label(%{runner: %PortRunner{pgid: pgid}}) when is_integer(pgid), do: "pgid:#{pgid}"
  defp process_label(%{adopted_pgid: pgid}) when is_integer(pgid), do: "pgid:#{pgid}"
  defp process_label(_state), do: nil

  defp error_payload(nil), do: nil

  defp error_payload(%Shoestring.Harness.Error{} = error) do
    %{
      "category" => Atom.to_string(error.category),
      "code" => error.code,
      "message" => error.message,
      "details" => Redaction.redact(error.details)
    }
  end

  defp result_payload(nil), do: nil

  defp result_payload(%{status: status} = result) do
    %{"status" => status, "artifact_id" => Map.get(result, :artifact_id)}
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc false
  @spec sanitize_extensions(map()) :: map()
  def sanitize_extensions(extensions) when is_map(extensions) do
    filtered =
      extensions
      |> Enum.reject(fn {key, _value} ->
        Regex.match?(@hidden_extension_pattern, to_string(key))
      end)
      |> Enum.filter(fn {key, _value} -> contracted_key?(to_string(key)) end)
      |> Enum.reject(fn {key, _value} -> forbidden_content_key?(to_string(key)) end)
      |> Enum.into(%{}, fn {key, value} -> {to_string(key), Redaction.redact(value)} end)

    case Shoestring.Harness.Contract.extensions(filtered) do
      {:ok, _extensions} ->
        filtered

      {:error, _reason} ->
        # Fail closed at field level: the core event (kind/ordinal/identity)
        # still lands with an explicit marker instead of uncontracted data.
        %{"shoestring.elf:extensions_dropped" => true}
    end
  end

  def sanitize_extensions(_extensions), do: %{}

  # Mirrors `Shoestring.Harness.Contract` namespacing so uncontracted adapter
  # data can never reach the trajectory: namespace + colon + content key.
  defp contracted_key?(key) do
    Regex.match?(~r/\A[a-z0-9][a-z0-9.-]{0,62}:[A-Za-z0-9_.-]{1,63}\z/, key)
  end

  # Transcript-shaped content is never canonical domain state.
  defp forbidden_content_key?(key) do
    content = key |> String.split(":", parts: 2) |> List.last()

    content in ~w(
      transcript raw_transcript raw_output stdout stderr prompt_messages messages
      model_response response_text completion_text
    )
  end

  defp check_event_bytes(state, payload) do
    if byte_size(Jason.encode!(payload)) > state.max_event_bytes do
      {:error, :event_overflow}
    else
      :ok
    end
  end

  # -- OS supervision --

  defp handle_os_data(state, bytes) do
    if state.terminal != nil do
      {:noreply, state}
    else
      max = runner_max_bytes(state)
      total = byte_size(state.os_buffer) + byte_size(bytes)

      if total > max do
        overflow_shutdown(%{state | output_overflowed?: true})
      else
        {:noreply, %{state | os_buffer: state.os_buffer <> bytes}}
      end
    end
  end

  defp handle_os_exit(state, status) do
    state = %{state | os_exit: {:exit_status, status}}

    if state.runner != nil do
      _ = PortRunner.close(state.runner)
    end

    state = %{state | runner: nil}

    cond do
      state.terminal != nil ->
        {:noreply, state}

      state.adapter_verdict != :none ->
        stop_with_terminal(
          state,
          Classifier.classify(state.adapter_verdict, state.os_exit, state.cancel_requested?)
        )

      state.pending_events == [] ->
        finish_after_stream(state)

      true ->
        # The child exited early but the adapter stream may still hold the
        # verdict (or prove the quiet-but-working case): keep consuming.
        {:noreply, state}
    end
  end

  defp finish_after_stream(state) do
    cond do
      state.terminal != nil ->
        {:noreply, state}

      state.events_overflow? or state.output_overflowed? ->
        overflow_shutdown(state)

      state.adapter_verdict != :none ->
        _ = terminate_owned_group(state)

        stop_with_terminal(
          state,
          Classifier.classify(state.adapter_verdict, state.os_exit, state.cancel_requested?)
        )

      owned_group_alive?(state) and state.os_exit == :unknown ->
        # Quiet but working (or an adopted orphan with no verdict yet): the
        # group is alive and nothing declared the run over, so do NOT
        # terminate and do NOT report. Keep supervising; staleness evidence is
        # collected on demand via `Shoestring.Elves.Staleness.collect/3`,
        # never by a timer here.
        {:noreply, state}

      owned_group_alive?(state) ->
        # The direct child is gone but stragglers linger: bounded reap, then
        # report what the OS exit says. This is termination of a run whose
        # primary already exited — not a timer kill of working processes.
        _ = terminate_owned_group(state)

        stop_with_terminal(
          state,
          Classifier.classify(:no_verdict, state.os_exit, state.cancel_requested?)
        )

      true ->
        stop_with_terminal(
          state,
          Classifier.classify(:no_verdict, state.os_exit, state.cancel_requested?)
        )
    end
  end

  defp overflow_shutdown(state) do
    _ = terminate_owned_group(state)
    stop_with_terminal(state, Classifier.overflow())
  end

  defp owned_pgid(%{runner: %PortRunner{pgid: pgid}}), do: pgid
  defp owned_pgid(%{adopted_pgid: pgid}), do: pgid
  defp owned_pgid(_state), do: nil

  defp owned_group_alive?(state) do
    case owned_pgid(state) do
      nil -> false
      pgid -> PortRunner.alive_id?(pgid)
    end
  end

  defp runner_max_bytes(%{runner: %PortRunner{max_output_bytes: max}}), do: max

  defp runner_max_bytes(state),
    do: Keyword.get(state.runner_opts, :max_output_bytes, PortRunner.default_max_output_bytes())

  defp terminate_owned_group(state) do
    case state.runner do
      nil ->
        case owned_pgid(state) do
          nil -> :ok
          pgid -> terminate_pgid(pgid, state.runner_opts)
        end

      runner ->
        _ = PortRunner.terminate(runner, state.runner_opts)
        :ok
    end
  end

  defp terminate_pgid(pgid, opts) do
    grace_ms = Keyword.get(opts, :kill_grace_ms, 5_000)
    _ = PortRunner.killpg_id(pgid, "TERM")
    _ = wait_until_dead(pgid, grace_ms)

    if PortRunner.alive_id?(pgid) do
      _ = PortRunner.killpg_id(pgid, "KILL")
      _ = wait_until_dead(pgid, 5_000)
    end

    :ok
  end

  defp wait_until_dead(pgid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_dead(pgid, deadline)
  end

  defp poll_dead(pgid, deadline) do
    cond do
      not PortRunner.alive_id?(pgid) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :timeout

      true ->
        Process.sleep(20)
        poll_dead(pgid, deadline)
    end
  end

  # -- Terminal reporting (idempotent) --

  # Commits one terminal state. Returns `{:duplicate, state}` when this Elf
  # (or a previous attempt — the durable check below) already reported, so
  # crashes, retries, and concurrent exits converge on a single terminal
  # event. Callers adapt the result to their callback context.
  defp commit_terminal(state, terminal) do
    cond do
      state.terminal != nil ->
        {:duplicate, state}

      terminal_recorded?(state) ->
        state = %{state | terminal: read_terminal(state)}
        notify_terminal(state)
        {:duplicate, state}

      true ->
        _ = persist_log_artifact(state)
        _ = append_terminal_event(state, terminal)
        state = %{state | terminal: terminal}
        notify_terminal(state)
        {:terminal, state}
    end
  end

  defp stop_with_terminal(state, terminal) do
    case commit_terminal(state, terminal) do
      {:duplicate, state} -> {:noreply, state}
      {:terminal, state} -> {:stop, :normal, state}
    end
  end

  defp append_terminal_event(state, terminal) do
    attrs = %{
      "type" => Classifier.event_type(terminal),
      "schema_version" => 1,
      "actor" => "elf",
      "occurred_at" => Clock.now(state.clock),
      "idempotency_key" => "elf-terminal:#{state.dispatch_id}",
      "payload" => Classifier.event_payload(state.run_id, terminal)
    }

    case Trajectory.append(state.goal_id, attrs,
           trusted: [task_id: state.task_id, run_id: state.run_id]
         ) do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_log_artifact(state) do
    if byte_size(state.os_buffer) == 0 do
      :ok
    else
      bytes = Redaction.redact(state.os_buffer)
      bytes = if is_binary(bytes), do: bytes, else: state.os_buffer

      max = runner_max_bytes(state)

      {bytes, truncated?} =
        if byte_size(bytes) > max do
          {binary_part(bytes, 0, max), true}
        else
          {bytes, state.output_overflowed?}
        end

      case ArtifactStore.put(
             state.goal_id,
             bytes,
             %{media_type: "text/plain", redacted: true},
             task_id: state.task_id
           ) do
        {:ok, artifact} -> append_artifact_event(state, artifact, byte_size(bytes), truncated?)
        {:error, _reason} -> :ok
      end
    end
  end

  defp append_artifact_event(state, artifact, byte_size_value, truncated?) do
    payload = %{
      "run_id" => state.run_id,
      "source_event_id" => "elf-log:#{state.dispatch_id}",
      "ordinal" => state.event_count + 1,
      "occurred_at" => DateTime.to_iso8601(Clock.now(state.clock)),
      "kind" => "artifact",
      "process_id" => process_label(state),
      "provider_session_id" => state.provider_session_id,
      "artifact_id" => artifact.id,
      "extensions" => %{
        "elf.log.byte_size" => byte_size_value,
        "elf.log.truncated" => truncated?,
        "elf.log.sha256" => artifact.sha256
      }
    }

    attrs = %{
      "type" => "harness.event_recorded",
      "schema_version" => 1,
      "actor" => "elf",
      "occurred_at" => Clock.now(state.clock),
      "idempotency_key" => "elf-log:#{state.dispatch_id}",
      "payload" => payload
    }

    case Trajectory.append(state.goal_id, attrs,
           trusted: [task_id: state.task_id, run_id: state.run_id]
         ) do
      {:ok, _event} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp notify_terminal(%{notify: nil}), do: :ok

  defp notify_terminal(%{notify: pid, run_id: run_id, terminal: terminal})
       when is_pid(pid) do
    send(pid, {:elf_terminal, run_id, terminal})
    :ok
  end
end
