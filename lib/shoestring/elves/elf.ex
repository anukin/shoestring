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
  alias Shoestring.State
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{ArtifactStore, Redaction, TrajectoryEvent}
  alias Shoestring.Worktrees

  @default_max_events_per_run 1_000
  @default_max_event_bytes 32_768
  @default_event_interval_ms 0
  @default_adapter_poll_ms 25
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
          adapter_identity: Shoestring.Harness.RunIdentity.t() | nil,
          process_owner: :runner | :adapter,
          command: [binary()],
          env: [{binary(), binary()}],
          runner_opts: keyword(),
          event_interval_ms: non_neg_integer(),
          adapter_poll_ms: pos_integer(),
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
          progress_count: non_neg_integer(),
          provider_session_id: String.t() | nil,
          os_buffer: binary(),
          output_overflowed?: boolean(),
          lease_bounds: Shoestring.Cobbler.LeaseBounds.t() | nil,
          lease_grant_id: Ecto.UUID.t() | nil,
          lease_deadline: DateTime.t() | nil,
          lease_stop_requested?: boolean(),
          lease_settled?: boolean(),
          lease_checkpointed?: boolean(),
          lease_checkpoint_id: Ecto.UUID.t() | nil
        }

  defstruct [
    :goal_id,
    :run_id,
    :task_id,
    :dispatch_id,
    :request,
    :adapter,
    :adapter_opts,
    :adapter_identity,
    :process_owner,
    :command,
    :env,
    :runner_opts,
    :event_interval_ms,
    :adapter_poll_ms,
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
    progress_count: 0,
    provider_session_id: nil,
    os_buffer: "",
    output_overflowed?: false,
    lease_bounds: nil,
    lease_grant_id: nil,
    lease_deadline: nil,
    lease_stop_requested?: false,
    lease_settled?: false,
    lease_checkpointed?: false,
    lease_checkpoint_id: nil
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
      process_owner: Keyword.get(opts, :process_owner, :runner),
      command: Keyword.get(opts, :command, ["sleep", "30"]),
      env: Keyword.get(opts, :env, []),
      runner_opts: Keyword.get(opts, :runner_opts, []),
      event_interval_ms: Keyword.get(opts, :event_interval_ms, @default_event_interval_ms),
      adapter_poll_ms: Keyword.get(opts, :adapter_poll_ms, @default_adapter_poll_ms),
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
  def handle_call({:cancel, opts}, _from, state) do
    if state.terminal != nil do
      {:reply, {:ok, :already_terminal}, state}
    else
      state = %{state | cancel_requested?: true}
      _ = append_cancelling(state)
      _ = cancel_adapter(state, opts)
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
  def handle_info(:poll_adapter, state) do
    if state.terminal == nil do
      begin_streaming(state)
    else
      {:noreply, state}
    end
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
    rows =
      state.repo.all(
        from event in TrajectoryEvent,
          where:
            event.goal_id == ^state.goal_id and event.run_id == ^state.run_id and
              event.type == "harness.event_recorded" and not is_nil(event.idempotency_key),
          select: {event.idempotency_key, event.payload}
      )

    # event_count is the classifier's observed-adapter-events input: it counts
    # newly persisted ADAPTER events (after_ingest/3), one per
    # "elf-event:<dispatch>:<source>" key. It must be restored alongside seen,
    # or a resumed Elf that skips its re-streamed events reports a run that
    # genuinely produced events as transport/no_adapter_events.
    #
    # progress_count is the classifier's progress-events input: it counts
    # adapter events whose kind is NOT in [:lifecycle, :capacity]. It must also
    # be restored, or a resumed run with pre-crash progress reports a false
    # transport/no_adapter_progress, and a resumed handshake-only run reports
    # a false run.completed.
    #
    # This is deliberately NOT MapSet.size(seen): seen also holds the Elf's
    # own log-artifact row ("elf-log:<dispatch>", same type, non-nil key),
    # which after_ingest/3 never counted. Only the elf-event: prefix is the
    # same population event_count counts.
    prefix = "elf-event:#{state.dispatch_id}:"

    {event_count, progress_count, keys} =
      Enum.reduce(rows, {0, 0, []}, fn {key, payload}, {evt_acc, prog_acc, keys_acc} ->
        if String.starts_with?(key, prefix) do
          kind = if is_map(payload), do: payload["kind"] || payload[:kind], else: nil
          prog = if progress_kind?(kind), do: 1, else: 0
          {evt_acc + 1, prog_acc + prog, [key | keys_acc]}
        else
          {evt_acc, prog_acc, [key | keys_acc]}
        end
      end)

    %{
      state
      | seen: MapSet.new(keys),
        event_count: event_count,
        progress_count: progress_count
    }
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
         {:ok, state} <- prepare_adapter_workdir(state),
         {:ok, identity} <- start_adapter(state),
         {:ok, state} <- attach_owned_process(%{state | adapter_identity: identity}, identity) do
      state = %{state | provider_session_id: identity.provider_session_id}

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
    terminal = Classifier.launch_failed("elf_launch_crashed")
    _ = maybe_terminal_checkpoint(state, terminal)

    _ =
      try do
        append_terminal_event(state, terminal)
      rescue
        _error -> :ok
      catch
        _kind, _reason -> :ok
      end

    {:stop, :normal, %{state | terminal: terminal}}
  end

  defp append_starting(state) do
    append_run_event(state, "run.starting", %{"run_id" => state.run_id}, "elf-starting:")
  end

  defp append_running(state) do
    pgid = owned_pgid(state)

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
    adapter_opts = maybe_mark_elf_owned_group(adapter_opts, state.process_owner)
    state.adapter.start(state.request, adapter_opts)
  end

  # When the adapter owns the OS process (`process_owner: :adapter`), the Elf
  # adopts that process group after the handshake and reaps it after the
  # verdict. The adapter session must not tear the group down on its own
  # success path first: a self-reap between the Elf's identity await and its
  # group-leader verify fails launch as `group_leader_unverifiable` under
  # scheduler pressure. Other adapters ignore the unknown key.
  defp maybe_mark_elf_owned_group(adapter_opts, :adapter) do
    Map.put_new(adapter_opts, :elf_owned_process_group, true)
  end

  defp maybe_mark_elf_owned_group(adapter_opts, _process_owner), do: adapter_opts

  defp prepare_adapter_workdir(%{process_owner: :runner} = state), do: {:ok, state}

  defp prepare_adapter_workdir(%{process_owner: :adapter} = state) do
    with {:ok, path} <- resolve_worktree_path(state) do
      {:ok, %{state | adapter_opts: Map.put(state.adapter_opts, :workdir, path)}}
    end
  end

  defp prepare_adapter_workdir(_state), do: {:error, :invalid_process_owner}

  defp resolve_worktree_path(state) do
    case Keyword.get(state.runner_opts, :cd) do
      path when is_binary(path) -> recognized_worktree_path(path, state.request.workspace_ref)
      nil -> recognized_workspace_ref(state.request.workspace_ref)
      _other -> {:error, :invalid_worktree}
    end
  end

  defp recognized_workspace_ref(workspace_ref) when is_binary(workspace_ref) do
    root = Path.expand(State.path(:worktrees))
    candidate = Path.expand(Path.join(root, workspace_ref))

    if candidate != root and String.starts_with?(candidate, root <> "/") do
      recognized_worktree_path(candidate, workspace_ref)
    else
      {:error, :invalid_worktree}
    end
  end

  defp recognized_workspace_ref(_workspace_ref), do: {:error, :invalid_worktree}

  defp recognized_worktree_path(path, workspace_ref) do
    try do
      case Worktrees.get(Path.expand(path)) do
        {:ok, worktree} when worktree.workspace_ref == workspace_ref -> {:ok, worktree.path}
        {:ok, _worktree} -> {:error, :worktree_mismatch}
        {:error, _reason} -> {:error, :worktree_not_found}
      end
    rescue
      _error -> {:error, :worktree_not_found}
    catch
      _kind, _reason -> {:error, :worktree_not_found}
    end
  end

  defp attach_owned_process(%{process_owner: :runner} = state, _identity) do
    case spawn_group(state) do
      {:ok, runner} -> {:ok, %{state | runner: runner}}
      {:error, _reason} = error -> error
    end
  end

  defp attach_owned_process(%{process_owner: :adapter} = state, identity) do
    with {:ok, pgid} <- parse_adapter_pgid(identity.process_id) do
      state = %{state | adopted_pgid: pgid}

      case PortRunner.verify_group_leader(pgid) do
        :ok ->
          {:ok, state}

        {:error, _reason} = error ->
          _ = cancel_adapter(state, [])
          _ = terminate_owned_group(state)
          _ = release_adapter(state)
          error
      end
    end
  end

  defp parse_adapter_pgid(process_id) when is_binary(process_id) do
    case Integer.parse(process_id) do
      {pgid, ""} when pgid > 1 -> {:ok, pgid}
      _other -> {:error, :os_pid_unavailable}
    end
  end

  defp parse_adapter_pgid(_process_id), do: {:error, :os_pid_unavailable}

  defp spawn_group(state) do
    runner_opts = [env: state.env] ++ state.runner_opts

    runner_opts = worktree_runner_opts(runner_opts, state.request.workspace_ref)

    PortRunner.spawn(state.command, runner_opts)
  end

  defp worktree_runner_opts(runner_opts, workspace_ref) when is_binary(workspace_ref) do
    root = Path.expand(State.path(:worktrees))
    candidate = Path.expand(Path.join(root, workspace_ref))

    if candidate != root and String.starts_with?(candidate, root <> "/") and
         File.dir?(candidate) do
      try do
        case Worktrees.get(candidate) do
          {:ok, worktree} -> Keyword.put_new(runner_opts, :cd, worktree.path)
          {:error, _reason} -> runner_opts
        end
      rescue
        _error -> runner_opts
      catch
        _kind, _reason -> runner_opts
      end
    else
      runner_opts
    end
  end

  defp worktree_runner_opts(runner_opts, _workspace_ref), do: runner_opts

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

    identity =
      state.adapter_identity ||
        %Shoestring.Harness.RunIdentity{
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
    state = %{
      state
      | seen: MapSet.put(state.seen, key),
        event_count: state.event_count + 1,
        progress_count: state.progress_count + progress_increment(event.kind)
    }

    # Lease loop (WP C, loop-closure I2): advances the run's execution-lease
    # bounds from this normalized event, marks renewal-due at the configured
    # boundary or deadline, runs the renewal sequence at item.completed, and
    # enters the reactive checkpoint path on in-flight exhaustion. Never
    # interrupts a mutation mid-item and never crashes the run (see
    # `lease_account/2`).
    state = lease_account(state, event)

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

  defp progress_kind?(kind) when kind in [:lifecycle, :capacity, "lifecycle", "capacity"],
    do: false

  defp progress_kind?(kind) when is_atom(kind) or is_binary(kind), do: true
  defp progress_kind?(_kind), do: false

  defp progress_increment(kind) do
    if progress_kind?(kind), do: 1, else: 0
  end

  defp verdict_of(%HarnessEvent{kind: :result, result: %{status: status}})
       when is_binary(status) do
    {:result, status}
  end

  defp verdict_of(%HarnessEvent{kind: :error, error: %Shoestring.Harness.Error{} = error}) do
    {:error, error}
  end

  defp verdict_of(_event), do: :none

  # -- Lease loop: bounds, renewal, reactive checkpoint (WP C, loop-closure I2) --
  #
  # Pinned wiring (P1–P5):
  #
  # - Bounds advance only from normalized `HarnessEvent`s ingested here (the
  #   live buffer), keyed by the run's lease loaded by `run_id`. No lease (or
  #   any unknown lease state) means no accounting — a leased-out run is never
  #   crashed by this path.
  # - Counting follows the `LeaseBounds` T2 rule (message completions, never
  #   delta frames); the item.completed boundary is derived from the live
  #   counters (this event incremented responses or tools), never redefined.
  # - On renewal-due or deadline: the durable `lease.renewal_due` marker is
  #   appended, a safe stop is ensured through the existing `LeaseBoundary`
  #   (exactly once — never restopped), and at the item.completed boundary the
  #   T2 renewal sequence runs (fresh snapshot + re-evaluate → renewed, or
  #   expired → decline: checkpoint contents plus `run.pausing` /
  #   `run.suspended` plus a durable sleep wake, see `decline_lease/2`).
  # - Renewal re-arms (re-loop P1): a `:renewed` outcome resets the spend
  #   baseline (`LeaseBounds.new_epoch/1`) and clears the settled/stop
  #   latches, so a later exhaustion re-fires the full sequence repeatedly
  #   (fresh snapshot + re-evaluate each time) until the unchanged deadline
  #   bounds total renewals. Stop hygiene (re-loop P3): the stop flag is set
  #   only on an actual `:stop_requested`, and the boundary sequence runs
  #   when a stop was requested OR none is required (budget-due renews with
  #   no session stop; only the deadline path stops first).
  # - On in-flight exhaustion the reactive checkpoint path builds checkpoint
  #   contents through the T3 `Checkpoints` writer (used as-is) and stops at
  #   the safe boundary; a mutation is never interrupted mid-item — every
  #   branch below only appends durable events and flips in-memory flags.
  # - No new trajectory event types, no timer processes. The deadline is
  #   evaluated inline on ingest with the Elf clock.
  #
  # For adapters without a live session (notably the hermetic `Fake`), no
  # session exists to interrupt: the safe stop is recorded virtually (the flag
  # the renewal sequence requires) and ingestion still runs every item to its
  # own completion, so the boundary guarantee holds without an external call.
  defp lease_account(state, event) do
    lease_account_inner(state, event)
  rescue
    _error -> state
  catch
    _kind, _reason -> state
  end

  defp lease_account_inner(state, event) do
    case ensure_lease_bounds(state) do
      {:ok, state} ->
        previous = state.lease_bounds

        {bounds, effects} =
          Shoestring.Cobbler.LeaseBounds.advance(previous, event)

        state = %{state | lease_bounds: bounds}
        boundary? = spent_more?(previous, bounds)

        state =
          if :quota_refused in effects do
            quota_path(state)
          else
            state
          end

        state = due_path(state, effects)
        state = stop_path(state)
        renew_path(state, boundary?)

      :skip ->
        state
    end
  end

  # The item.completed boundary, derived — not redefined — from the T2 rule:
  # this normalized event spent responses or tools.
  defp spent_more?(previous, current) do
    current.responses > previous.responses or current.tools > previous.tools
  end

  defp exhausted?(state) do
    case state.lease_bounds do
      %Shoestring.Cobbler.LeaseBounds{} = bounds ->
        bounds.responses >= bounds.response_budget or bounds.tools >= bounds.tool_budget

      _other ->
        false
    end
  end

  defp due_level?(state) do
    case state.lease_bounds do
      %Shoestring.Cobbler.LeaseBounds{} = bounds ->
        Shoestring.Cobbler.LeaseBounds.due?(bounds)

      _other ->
        false
    end
  end

  defp deadline_passed?(state) do
    case state.lease_deadline do
      %DateTime{} = deadline ->
        DateTime.compare(Clock.now(state.clock), deadline) != :lt

      _other ->
        false
    end
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  # Loads the run's lease by `run_id` on first need and rebuilds spend from
  # durable normalized events, so a lease granted while the stream is already
  # flowing still counts exactly (idempotent on `source_event_id`: the current
  # event is already persisted, so re-advancing it is a no-op).
  defp ensure_lease_bounds(%{lease_bounds: %Shoestring.Cobbler.LeaseBounds{}} = state) do
    {:ok, state}
  end

  defp ensure_lease_bounds(state) do
    case active_lease_for(state) do
      {:ok, record} ->
        bounds =
          Shoestring.Cobbler.LeaseBounds.new(%{
            grant_id: record.id,
            run_id: record.run_id,
            response_budget: record.response_budget,
            tool_budget: record.tool_budget,
            response_reserve: record.response_reserve,
            tool_reserve: record.tool_reserve,
            checkpoint_cadence: record.checkpoint_cadence
          })

        {bounds, _effects} = rebuild_spend(state, bounds)

        {:ok,
         %{
           state
           | lease_bounds: bounds,
             lease_grant_id: record.id,
             lease_deadline: record.deadline
         }}

      :skip ->
        :skip
    end
  rescue
    _error -> :skip
  catch
    _kind, _reason -> :skip
  end

  defp active_lease_for(state) do
    query =
      from lease in Shoestring.Harness.ExecutionLeaseRecord,
        where: lease.run_id == ^state.run_id,
        order_by: [desc: lease.projection_sequence, asc: lease.id],
        limit: 1

    case state.repo.one(query) do
      %Shoestring.Harness.ExecutionLeaseRecord{status: status} = record
      when status in [
             "proposed",
             "granted",
             "active",
             "renewal_due",
             "renewed",
             "expired",
             "revoked",
             "checkpoint_required"
           ] ->
        {:ok, record}

      _other ->
        :skip
    end
  rescue
    _error -> :skip
  catch
    _kind, _reason -> :skip
  end

  defp rebuild_spend(state, bounds) do
    rows =
      state.repo.all(
        from event in TrajectoryEvent,
          where:
            event.goal_id == ^state.goal_id and event.run_id == ^state.run_id and
              event.type == "harness.event_recorded",
          order_by: [asc: event.sequence],
          select: event.payload
      )

    events = Enum.flat_map(rows, &persisted_harness_event(state, &1))
    Shoestring.Cobbler.LeaseBounds.drain(bounds, state.run_id, events)
  rescue
    _error -> {bounds, []}
  catch
    _kind, _reason -> {bounds, []}
  end

  defp persisted_harness_event(state, payload) when is_map(payload) do
    with kind when not is_nil(kind) <- persisted_kind(payload),
         source when is_binary(source) <- payload["source_event_id"],
         extensions when is_map(extensions) <- payload["extensions"] do
      [
        %HarnessEvent{
          version: 1,
          run_id: payload["run_id"] || state.run_id,
          source_event_id: source,
          ordinal: payload["ordinal"] || 1,
          occurred_at: persisted_time(state, payload),
          kind: kind,
          process_id: nil,
          provider_session_id: nil,
          artifact_id: nil,
          capacity_snapshot_id: nil,
          error: persisted_error(payload),
          result: nil,
          extensions: extensions
        }
      ]
    else
      _other -> []
    end
  rescue
    _error -> []
  catch
    _kind, _reason -> []
  end

  defp persisted_harness_event(_state, _payload), do: []

  defp persisted_kind(payload) do
    case payload["kind"] do
      kind when is_binary(kind) ->
        atom = String.to_existing_atom(kind)
        if atom in HarnessEvent.kinds(), do: atom, else: nil

      _other ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  defp persisted_time(state, payload) do
    case payload["occurred_at"] do
      at when is_binary(at) ->
        case DateTime.from_iso8601(at) do
          {:ok, time, _offset} -> time
          _error -> Clock.now(state.clock)
        end

      _other ->
        Clock.now(state.clock)
    end
  end

  defp persisted_error(%{"kind" => "error", "error" => %{"category" => "quota_refused"} = error}) do
    Shoestring.Harness.Error.new(
      :quota_refused,
      error["code"] || "quota_refused",
      error["message"] || "quota refused",
      details: %{}
    )
  end

  defp persisted_error(_payload), do: nil

  # Marks renewal-due durably at the configured boundary or deadline.
  # Idempotent by LeaseStateMachine validation: an already-due lease simply
  # reports an error that is ignored here.
  defp due_path(state, effects) do
    if state.lease_grant_id != nil and (:renewal_due in effects or deadline_passed?(state)) do
      case Shoestring.Cobbler.Leases.transition(state.goal_id, state.lease_grant_id, :renewal_due,
             repo: state.repo
           ) do
        {:ok, _transition} -> state
        {:error, _reason} -> state
      end
    else
      state
    end
  rescue
    _error -> state
  catch
    _kind, _reason -> state
  end

  # Ensures a safe stop was requested through the existing LeaseBoundary —
  # exactly once. With no live session (hermetic Fake runs) the stop is
  # recorded virtually: ingestion still runs every in-flight item to its own
  # completion, so nothing is ever interrupted mid-item either way.
  #
  # Stop hygiene (lease re-loop): the stop-requested flag is set ONLY on an
  # actual `:stop_requested` from `LeaseBoundary.enforce/3`. A `:within_lease`
  # answer (budget-due with a live deadline — no session stop needed) leaves
  # the flag clear; the budget path renews at the boundary through
  # `stop_satisfied?/1` instead of through a stop that never happened.
  defp stop_path(%{lease_stop_requested?: true} = state), do: state

  defp stop_path(state) do
    if state.lease_bounds == nil or not (due_level?(state) or deadline_passed?(state)) do
      state
    else
      case resolve_session(state) do
        nil ->
          %{state | lease_stop_requested?: true}

        session ->
          now = Clock.now(state.clock)

          case Shoestring.Elves.LeaseBoundary.enforce(
                 session,
                 state.lease_deadline || now,
                 now: now
               ) do
            {:ok, :stop_requested} -> %{state | lease_stop_requested?: true}
            {:ok, :within_lease} -> state
            {:error, _reason} -> state
          end
      end
    end
  rescue
    _error -> state
  catch
    _kind, _reason -> state
  end

  defp resolve_session(state) do
    case Shoestring.Harness.CodexAppServer.lookup_session(state.run_id) do
      {:ok, pid} when is_pid(pid) ->
        if Process.alive?(pid), do: pid, else: nil

      _other ->
        nil
    end
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  # Runs the T2 renewal sequence at the item.completed boundary only: fresh
  # snapshot + re-evaluate → renewed, or expired → decline (checkpoint +
  # suspend + sleep wake, see `decline_lease/2`). Anything else (mid-item,
  # stop still required, already settled) waits without appending.
  #
  # Re-loop gating: boundary + (due or deadline-passed) + (stop requested OR
  # no stop required). Budget-due with a live deadline needs no session stop
  # and renews at the boundary; only the expired-deadline path stops the
  # session first.
  defp renew_path(%{lease_settled?: true} = state, _boundary?), do: state

  defp renew_path(state, boundary?) do
    cond do
      state.lease_bounds == nil -> state
      state.lease_grant_id == nil -> state
      not (due_level?(state) or deadline_passed?(state)) -> state
      not boundary? -> state
      not stop_satisfied?(state) -> state
      true -> run_renewal(state)
    end
  rescue
    _error -> state
  catch
    _kind, _reason -> state
  end

  # The stop precondition for the renewal sequence: an actual requested
  # session stop, or none required because the deadline has not passed
  # (budget-due renews at the boundary with no session stop).
  defp stop_satisfied?(state) do
    state.lease_stop_requested? or not deadline_passed?(state)
  end

  defp run_renewal(state) do
    opts = [
      repo: state.repo,
      now: Clock.now(state.clock),
      stop: :already_requested,
      boundary: :item_completed,
      observe: fn -> probe_capacity(state) end
    ]

    case Shoestring.Cobbler.LeaseRenewal.maybe_renew(state.goal_id, state.lease_grant_id, opts) do
      {:ok, %{outcome: :renewed}} ->
        rearm_epoch(state)

      {:ok, %{outcome: :expired}} ->
        decline_lease(state, "lease_exhausted")

      {:ok, :awaiting_boundary} ->
        state

      {:error, {:lease_not_renewable, _status}} ->
        # Already terminal elsewhere: still ensure checkpoint contents when
        # the allowance is exhausted, then settle so later items stay quiet.
        state =
          if exhausted?(state) do
            write_reactive_checkpoint(state, "lease_exhausted")
          else
            state
          end

        %{state | lease_settled?: true}

      {:error, _reason} ->
        state
    end
  rescue
    _error -> state
  catch
    _kind, _reason -> state
  end

  # Multi-renewal re-arm (lease re-loop P1): on a `:renewed` outcome the
  # spend baseline restarts as a new epoch from the renewed grant (same
  # budgets and deadline — deadlines still bound total renewals) and both
  # latches clear, so a later due/deadline re-fires the full sequence with
  # a fresh snapshot + re-evaluation each time. The stop latch clears too:
  # each epoch earns its own stop decision (virtual with no session, a fresh
  # idempotent `request_safe_stop` past the deadline, none when budget-due).
  defp rearm_epoch(state) do
    bounds =
      case state.lease_bounds do
        %Shoestring.Cobbler.LeaseBounds{} = bounds ->
          Shoestring.Cobbler.LeaseBounds.new_epoch(bounds)

        _other ->
          state.lease_bounds
      end

    %{state | lease_bounds: bounds, lease_settled?: false, lease_stop_requested?: false}
  end

  # The decline path (lease re-loop P2): checkpoint contents through the T3
  # writer (existing, used as-is), then the run sleeps — `run.pausing` /
  # `run.suspended` through the Elf's existing run-event helper — then a
  # durable sleep wake for the delayed recheck, then settle. Every step is
  # idempotent (checkpoint id, run-event keys, wakeup key are all stable per
  # dispatch), so a retry between steps replays instead of duplicating.
  defp decline_lease(state, reason) do
    state
    |> write_reactive_checkpoint(reason)
    |> suspend_run_for_decline()
    |> schedule_decline_wakeup()
    |> settle_on_checkpoint()
  end

  defp suspend_run_for_decline(state) do
    with :ok <-
           append_run_event(
             state,
             "run.pausing",
             %{"run_id" => state.run_id},
             "elf-pausing:"
           ),
         :ok <-
           append_run_event(
             state,
             "run.suspended",
             %{"run_id" => state.run_id},
             "elf-suspended:"
           ) do
      state
    else
      _error -> state
    end
  end

  # Schedules the decline sleep wake: a durable `cobbler_wakeups` row plus
  # an Oban `wakeup`-queue delivery attempt (durable delivery, never a
  # timer). The wake fires at the admission delayed-recheck default past
  # now; the command id is synthetic and stable per dispatch
  # (`"elf-lease-decline:<dispatch_id>"`), so the wakeup key makes repeat
  # declines replay instead of duplicating. Best-effort: a scheduling
  # failure never blocks the checkpoint + suspend + settle.
  defp schedule_decline_wakeup(state) do
    now = Clock.now(state.clock)

    wake_at =
      DateTime.add(
        now,
        Shoestring.Cobbler.AdmissionPolicy.default().delayed_recheck_seconds,
        :second
      )

    _ =
      Shoestring.Cobbler.Wakeups.schedule(state.goal_id,
        repo: state.repo,
        now: now,
        clock: state.clock,
        run_id: state.run_id,
        command_id: "elf-lease-decline:#{state.dispatch_id}",
        wake_at: wake_at,
        reason: "lease_decline_recheck"
      )

    state
  end

  # Immediate re-observe + re-evaluate on the Codex quota fast path (the
  # provider already halted the turn, so no stop/boundary wait): zero spend
  # here, spend accounting lives in `LeaseBounds`.
  defp quota_path(state) do
    if state.lease_grant_id == nil or state.lease_settled? do
      state
    else
      opts = [
        repo: state.repo,
        now: Clock.now(state.clock),
        observe: fn -> probe_capacity(state) end
      ]

      case Shoestring.Cobbler.LeaseRenewal.handle_quota_refusal(
             state.goal_id,
             state.lease_grant_id,
             opts
           ) do
        # Twin note (P4: quota path gating unchanged): unlike boundary
        # renewals, a quota renewal settles without starting a new spend
        # epoch — the refusal is zero-spend, so the live counters still
        # describe the grant's remaining allowance and must not be forgiven.
        {:ok, %{outcome: :renewed}} ->
          %{state | lease_settled?: true}

        {:ok, %{outcome: :expired}} ->
          decline_lease(state, "lease_exhausted")

        {:error, _reason} ->
          state
      end
    end
  rescue
    _error -> state
  catch
    _kind, _reason -> state
  end

  defp settle_on_checkpoint(%{lease_checkpointed?: true} = state) do
    %{state | lease_settled?: true}
  end

  defp settle_on_checkpoint(state), do: state

  # The reactive checkpoint path: deterministic, model-free checkpoint
  # contents through the T3 writer (used as-is, read-only), then the run
  # continues to the safe boundary — the item that just completed is durable
  # before this append, and ingestion is never interrupted mid-item.
  defp write_reactive_checkpoint(state, reason) do
    bounds = state.lease_bounds

    spent =
      case bounds do
        %Shoestring.Cobbler.LeaseBounds{} = bounds ->
          "spent #{bounds.responses} responses and #{bounds.tools} tools"

        _other ->
          "allowance exhausted"
      end

    {state, checkpoint_id} =
      case state.lease_checkpoint_id do
        nil ->
          id = Ecto.UUID.generate()
          {%{state | lease_checkpoint_id: id}, id}

        id ->
          {state, id}
      end

    inputs = %{
      checkpoint_id: checkpoint_id,
      goal_id: state.goal_id,
      run_id: state.run_id,
      acceptance_criteria: ["complete the supervised task per the goal acceptance contract"],
      repository_revision: "unknown",
      stop_reason: reason,
      provider_session_id: state.provider_session_id,
      evidence: ["reactive checkpoint for lease #{state.lease_grant_id}: #{spent}"],
      extensions: %{"shoestring.elf:lease_grant_id" => state.lease_grant_id}
    }

    case Shoestring.Harness.CheckpointFallback.build(inputs) do
      {:ok, checkpoint} ->
        case Shoestring.Harness.Checkpoints.record(state.goal_id, checkpoint,
               repo: state.repo,
               now: Clock.now(state.clock),
               actor: "elf"
             ) do
          {:ok, _recorded} -> %{state | lease_checkpointed?: true}
          {:error, _reason} -> state
        end

      {:error, _reason} ->
        state
    end
  rescue
    _error -> state
  catch
    _kind, _reason -> state
  end

  # Fresh observable capacity through the running adapter only (Fake in
  # hermetic tests, provider probe in production). Never raw provider output:
  # the snapshot struct is the admitted re-evaluation input.
  defp probe_capacity(state) do
    opts = Map.merge(%{clock: state.clock}, state.adapter_opts)
    state.adapter.probe(opts)
  rescue
    error -> {:error, {:observation_failed, error}}
  catch
    kind, reason -> {:error, {:observation_failed, {kind, reason}}}
  end

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

      state.process_owner == :adapter ->
        Process.send_after(self(), :poll_adapter, state.adapter_poll_ms)
        {:noreply, state}

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

      state.process_owner == :adapter ->
        Process.send_after(self(), :poll_adapter, state.adapter_poll_ms)
        {:noreply, state}

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
        # The observed adapter-event and progress-event counts travel with the
        # classification: zero observed events is transport/no_adapter_events;
        # zero progress events (only :lifecycle or :capacity handshakes) is
        # transport/no_adapter_progress, never a false completion.
        _ = terminate_owned_group(state)

        stop_with_terminal(
          state,
          Classifier.classify(
            :no_verdict,
            state.os_exit,
            state.cancel_requested?,
            state.event_count,
            state.progress_count
          )
        )

      true ->
        # Same observed-events and progress rules on the fully-reaped path:
        # zero adapter events fails as `transport/no_adapter_events`; zero
        # progress events fails as `transport/no_adapter_progress`.
        stop_with_terminal(
          state,
          Classifier.classify(
            :no_verdict,
            state.os_exit,
            state.cancel_requested?,
            state.event_count,
            state.progress_count
          )
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

  defp cancel_adapter(%{process_owner: :adapter, adapter_identity: identity} = state, opts)
       when not is_nil(identity) do
    if function_exported?(state.adapter, :cancel, 2) do
      adapter_opts =
        state.adapter_opts
        |> Map.merge(Map.new(opts))
        |> Map.put(:clock, state.clock)

      state.adapter.cancel(identity, adapter_opts)
    else
      :ok
    end
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp cancel_adapter(_state, _opts), do: :ok

  defp release_adapter(%{process_owner: :adapter, adapter_identity: identity} = state)
       when not is_nil(identity) do
    if function_exported?(state.adapter, :release, 1) do
      state.adapter.release(identity)
    else
      :ok
    end
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp release_adapter(_state), do: :ok

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
    _ = release_adapter(state)

    cond do
      state.terminal != nil ->
        {:duplicate, state}

      terminal_recorded?(state) ->
        state = %{state | terminal: read_terminal(state)}
        notify_terminal(state)
        {:duplicate, state}

      true ->
        _ = persist_log_artifact(state)
        _ = maybe_terminal_checkpoint(state, terminal)
        _ = append_terminal_event(state, terminal)
        state = %{state | terminal: terminal}
        notify_terminal(state)
        {:terminal, state}
    end
  end

  # Terminal-path recovery checkpoint (WP D loop-closure I3): on every
  # terminal, attempt a repo-evidence checkpoint BEFORE the terminal commit.
  # Checkpoint failure (including fallback build failure) never suppresses
  # the terminal commit: the error is logged with run/dispatch identity and
  # the terminal still appends. `run.*` payloads reject unknown keys
  # (EventRegistry) and no new trajectory event types are admitted, so the
  # terminal event itself is unchanged: the terminal-to-checkpoint link is
  # the deterministic checkpoint id
  # (`TerminalCheckpoint.checkpoint_id(run_id)`) plus the terminal key
  # carried in the checkpoint extensions.
  defp maybe_terminal_checkpoint(state, terminal) do
    case Shoestring.Elves.TerminalCheckpoint.record(state, terminal) do
      {:ok, _checkpoint_id} ->
        :ok

      {:error, reason} ->
        Logger.error("elf terminal checkpoint failed: #{inspect(reason)}",
          run_id: state.run_id,
          dispatch_id: state.dispatch_id,
          reason: inspect(reason)
        )

        :ok
    end
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
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
