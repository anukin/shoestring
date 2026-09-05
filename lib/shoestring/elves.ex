defmodule Shoestring.Elves do
  @moduledoc """
  Public boundary for the supervised single-Elf runtime (Work Package B).

  An Elf owns one bounded external harness run: durable intent first, then a
  supervised OS process group, live normalized event streaming, and exactly
  one idempotent terminal state.

  ## Ordering guarantee

  `start_run/3` persists `dispatch.requested`/run intent through
  `Shoestring.Harness.Dispatches.enqueue/3` — which also enqueues the Oban
  delivery carrying only durable identifiers — before any Elf or OS process
  exists. The Elf itself re-verifies intent and reconciles current
  run/trajectory state before spawning, so an Oban retry converges instead of
  duplicating an uncertain external effect.

  ## Cancellation

  `cancel_run/2` (and `cancel_dispatch/2`, which additionally cancels the Oban
  job) terminates the whole owned process group and reconciles durable state.
  Oban job cancellation alone is never treated as a terminal run event: the
  run is terminal only after the group is dead and `run.cancelled` is
  persisted.

  ## Staleness

  Quiet runs are evidence, not verdicts. `collect_evidence/3` persists a
  bounded, deduplicated evidence packet; nothing here interrupts, replaces, or
  duplicates an Elf on a timer.
  """

  import Ecto.Query

  alias Shoestring.Elves.{Elf, PortRunner, Staleness}
  alias Shoestring.Harness.{Clock, DispatchRecord, Dispatches, Identity, RunRecord, RunRequest}
  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.TrajectoryEvent

  @default_spawn_grace_ms 30_000

  @doc """
  Persists run intent + Oban delivery, then starts the supervising Elf.

  Returns `{:ok, pid}` for a fresh Elf or `{:ok, :already_running, pid}` when
  an Elf for the run is already alive. Intent (`dispatch.requested`) is
  durable before either outcome.
  """
  @spec start_run(RunRequest.t(), Identity.t(), keyword()) ::
          {:ok, pid()} | {:ok, :already_running, pid()} | {:error, term()}
  def start_run(%RunRequest{} = request, %Identity{} = identity, opts \\ []) do
    dispatch_opts = Keyword.take(opts, [:repo, :clock, :identifier, :writer_opts])

    with {:ok, dispatch, _job} <- Dispatches.enqueue(request, identity, dispatch_opts) do
      start_elf(request, dispatch, opts)
    end
  end

  @doc """
  Starts (or finds) the Elf for an already-enqueued dispatch without
  re-persisting intent. Used by the Oban effect path after
  `Dispatches.prepare_for_effect/2` has reconciled and claimed the dispatch.
  """
  @spec start_elf(RunRequest.t(), DispatchRecord.t(), keyword()) ::
          {:ok, pid()} | {:ok, :already_running, pid()} | {:error, term()}
  def start_elf(%RunRequest{} = request, %DispatchRecord{} = dispatch, opts \\ []) do
    supervisor = Keyword.get(opts, :supervisor, Shoestring.Elves.Supervisor)
    repo = Keyword.get(opts, :repo, Repo)

    case repo.get(RunRecord, dispatch.run_id) do
      nil ->
        {:error, :run_not_found}

      run ->
        elf_opts =
          elf_opts(request, run, dispatch, opts)
          |> Keyword.put(:repo, repo)

        case DynamicSupervisor.start_child(supervisor, {Elf, elf_opts}) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:ok, :already_running, pid}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc "Looks up the live Elf for a run, if any."
  @spec whereis(Ecto.UUID.t()) :: pid() | nil
  def whereis(run_id) do
    case Registry.lookup(Shoestring.Elves.Registry, run_id) do
      [{pid, _value}] -> if Process.alive?(pid), do: pid, else: nil
      [] -> nil
    end
  end

  @doc """
  Explicit cancellation: terminates the owned process group and reconciles
  durable state to `run.cancelled`. Works with or without a live Elf; when
  the run is already terminal returns `{:ok, :already_terminal}`.
  """
  @spec cancel_run(Ecto.UUID.t(), keyword()) ::
          {:ok, :cancelled | :already_terminal} | {:error, term()}
  def cancel_run(run_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, run} <- fetch_run(run_id, repo) do
      cond do
        terminal_event(run, repo) != nil ->
          {:ok, :already_terminal}

        whereis(run.id) != nil ->
          cancel_via_elf(run, opts)

        true ->
          cancel_without_elf(run, opts)
      end
    end
  end

  @doc """
  Cancels the Oban delivery (if any) and the Elf run. Job cancellation alone
  is not a terminal run event — this function always follows through to group
  termination + durable reconciliation, and documents that ordering.
  """
  @spec cancel_dispatch(Ecto.UUID.t(), keyword()) ::
          {:ok, :cancelled | :already_terminal} | {:error, term()}
  def cancel_dispatch(dispatch_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    case repo.get(DispatchRecord, dispatch_id) do
      nil ->
        {:error, :dispatch_not_found}

      %DispatchRecord{job_id: job_id} = dispatch ->
        _ = cancel_oban_job(job_id)
        cancel_run(dispatch.run_id, opts)
    end
  end

  @doc """
  Reconciles an uncertain run without duplicating its external effect:

    * terminal already recorded → `{:ok, :already_terminal}`;
    * live Elf → `{:ok, :running}`;
    * live owned process group, no Elf → adopts it under a new Elf (no new
      spawn, no new dispatch) and persists an adoption evidence packet →
      `{:ok, :adopted}`;
    * dead/missing group, no Elf → records the exit explicitly from durable
      evidence (recorded adapter verdict when present, `supervisor_crash`
      otherwise) → `{:ok, :reconciled_terminal}`;
    * claimed dispatch younger than `spawn_grace_ms:` → `{:ok, :deferred}`
      (too early to judge; the Elf may simply not have started yet).
  """
  @spec reconcile(Ecto.UUID.t(), keyword()) ::
          {:ok, :already_terminal | :running | :adopted | :reconciled_terminal | :deferred}
          | {:error, term()}
  def reconcile(run_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, run} <- fetch_run(run_id, repo) do
      cond do
        terminal_event(run, repo) != nil ->
          {:ok, :already_terminal}

        whereis(run.id) != nil ->
          {:ok, :running}

        true ->
          reconcile_orphan(run, opts)
      end
    end
  end

  @doc "Reads the recorded terminal state for a run, if any."
  @spec terminal_of(Ecto.UUID.t(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def terminal_of(run_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, run} <- fetch_run(run_id, repo) do
      {:ok, terminal_event(run, repo)}
    end
  end

  @doc "Collects and persists a staleness evidence packet. Never interrupts the run."
  @spec collect_evidence(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, :persisted | :duplicate, TrajectoryEvent.t()} | {:error, term()}
  def collect_evidence(run_id, reason, opts \\ []) do
    Staleness.collect(run_id, reason, opts)
  end

  @doc "Rebuilds a `RunRequest` from its durable `RunRecord` (Oban effect path)."
  @spec request_from_run(RunRecord.t()) :: {:ok, RunRequest.t()} | {:error, term()}
  def request_from_run(%RunRecord{} = run) do
    RunRequest.new(%{
      version: run.request_version,
      goal_id: run.goal_id,
      task_id: run.task_id,
      workspace_ref: run.workspace_ref,
      prompt: run.prompt,
      continuation: continuation_from_run(run.continuation),
      policy: run.policy,
      requested_capabilities: capabilities_from_run(run.requested_capabilities),
      dispatch_id: run.dispatch_id,
      extensions: run.extensions || %{}
    })
  end

  # -- Private helpers --

  defp elf_opts(request, run, dispatch, opts) do
    [
      goal_id: run.goal_id,
      run_id: run.id,
      task_id: run.task_id,
      dispatch_id: dispatch.dispatch_id,
      request: request,
      adapter: Keyword.get(opts, :adapter, Shoestring.Harness.Fake),
      adapter_opts: Keyword.get(opts, :adapter_opts, default_adapter_opts(opts)),
      command: Keyword.get(opts, :command, ["sleep", "30"]),
      env: Keyword.get(opts, :env, []),
      runner_opts: Keyword.get(opts, :runner_opts, default_runner_opts()),
      event_interval_ms: Keyword.get(opts, :event_interval_ms, 0),
      max_events_per_run: Keyword.get(opts, :max_events_per_run, 1_000),
      max_event_bytes: Keyword.get(opts, :max_event_bytes, 32_768),
      clock: Keyword.get(opts, :clock, Shoestring.Harness.SystemClock),
      notify: Keyword.get(opts, :notify),
      orphan_poll_ms: Keyword.get(opts, :orphan_poll_ms, 100)
    ]
  end

  defp default_adapter_opts(opts) do
    case Keyword.fetch(opts, :scenario) do
      {:ok, scenario} -> %{scenario: scenario}
      :error -> %{}
    end
  end

  defp default_runner_opts do
    [kill_grace_ms: 5_000, reap_timeout_ms: 5_000]
  end

  defp fetch_run(run_id, repo) do
    case repo.get(RunRecord, run_id) do
      %RunRecord{} = run -> {:ok, run}
      nil -> {:error, :run_not_found}
    end
  end

  defp terminal_event(run, repo) do
    query =
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^run.goal_id and event.run_id == ^run.id and
            event.type in ["run.completed", "run.failed", "run.cancelled"],
        order_by: [desc: event.sequence],
        limit: 1

    case repo.one(query) do
      %TrajectoryEvent{type: "run.completed"} ->
        %{class: :completed}

      %TrajectoryEvent{type: "run.cancelled"} ->
        %{class: :cancelled}

      %TrajectoryEvent{type: "run.failed", payload: payload} ->
        %{class: :failed, payload: payload}

      nil ->
        nil
    end
  end

  defp cancel_via_elf(run, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    case Elf.cancel(whereis(run.id), timeout: timeout) do
      {:ok, :cancelled} -> {:ok, :cancelled}
      {:ok, :already_terminal} -> {:ok, :already_terminal}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:elf_cancel_failed, reason}}
  end

  defp cancel_without_elf(run, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    clock = Keyword.get(opts, :clock, Shoestring.Harness.SystemClock)

    _ = terminate_recorded_group(run, repo, opts)
    append_cancelled(run, clock, repo)
  end

  defp terminate_recorded_group(run, repo, opts) do
    case recorded_pgid(run, repo) do
      nil ->
        :ok

      pgid ->
        grace_ms = Keyword.get(opts, :kill_grace_ms, 5_000)
        _ = PortRunner.killpg_id(pgid, "TERM")
        _ = wait_until_dead(pgid, grace_ms)

        if PortRunner.alive_id?(pgid) do
          _ = PortRunner.killpg_id(pgid, "KILL")
          _ = wait_until_dead(pgid, 5_000)
        end

        :ok
    end
  end

  defp recorded_pgid(run, repo) do
    query =
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^run.goal_id and event.run_id == ^run.id and
            event.type == "run.running",
        order_by: [desc: event.sequence],
        limit: 1,
        select: event.payload

    case repo.one(query) do
      %{"process_id" => "pgid:" <> rest} ->
        case Integer.parse(rest) do
          {pgid, _rest} when pgid > 1 -> pgid
          _other -> nil
        end

      %{"process_id" => process_id} when is_binary(process_id) ->
        case Integer.parse(process_id) do
          {pgid, _rest} when pgid > 1 -> pgid
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp append_cancelled(run, clock, _repo) do
    for type <- ["run.cancelling", "run.cancelled"] do
      prefix = if type == "run.cancelling", do: "elf-cancelling:", else: "elf-terminal:"

      attrs = %{
        "type" => type,
        "schema_version" => 1,
        "actor" => "elf",
        "occurred_at" => Clock.now(clock),
        "idempotency_key" => "#{prefix}#{run.dispatch_id}",
        "payload" => %{"run_id" => run.id}
      }

      case Trajectory.append(run.goal_id, attrs, trusted: [task_id: run.task_id, run_id: run.id]) do
        {:ok, _event} -> :ok
        {:error, reason} -> throw({:append_failed, reason})
      end
    end

    {:ok, :cancelled}
  catch
    {:append_failed, reason} -> {:error, reason}
  end

  defp cancel_oban_job(nil), do: :ok

  defp cancel_oban_job(job_id) do
    try do
      Oban.cancel_job(job_id)
    rescue
      _error -> :ok
    catch
      _kind, _reason -> :ok
    end
  end

  defp reconcile_orphan(run, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    case recorded_pgid(run, repo) do
      pgid when is_integer(pgid) ->
        if PortRunner.alive_id?(pgid) do
          adopt_orphan(run, pgid, opts)
        else
          reconcile_exited(run, opts)
        end

      nil ->
        reconcile_never_spawned(run, opts)
    end
  end

  defp adopt_orphan(run, pgid, opts) do
    supervisor = Keyword.get(opts, :supervisor, Shoestring.Elves.Supervisor)
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, request} <- request_from_run(run),
         {:ok, dispatch} <- fetch_dispatch(run, repo) do
      elf_opts =
        elf_opts(request, run, dispatch, opts)
        |> Keyword.put(:repo, repo)
        |> Keyword.put(:adopt_pgid, pgid)

      case DynamicSupervisor.start_child(supervisor, {Elf, elf_opts}) do
        {:ok, _pid} ->
          _ = Staleness.collect(run.id, "elf_adopted", opts)
          {:ok, :adopted}

        {:error, {:already_started, _pid}} ->
          {:ok, :running}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp fetch_dispatch(run, repo) do
    case repo.get(DispatchRecord, run.dispatch_id) do
      %DispatchRecord{} = dispatch -> {:ok, dispatch}
      nil -> {:error, :dispatch_not_found}
    end
  end

  defp reconcile_exited(run, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    clock = Keyword.get(opts, :clock, Shoestring.Harness.SystemClock)

    terminal =
      case recorded_adapter_verdict(run, repo) do
        :none -> Shoestring.Elves.Classifier.supervisor_crash()
        verdict -> Shoestring.Elves.Classifier.classify(verdict, :unknown, false)
      end

    append_reconciled_terminal(run, terminal, clock)
  end

  defp reconcile_never_spawned(run, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    clock = Keyword.get(opts, :clock, Shoestring.Harness.SystemClock)
    grace_ms = Keyword.get(opts, :spawn_grace_ms, @default_spawn_grace_ms)

    case repo.get(DispatchRecord, run.dispatch_id) do
      %DispatchRecord{status: "effect_started", updated_at: updated_at} ->
        if within_grace?(updated_at, grace_ms, clock) do
          {:ok, :deferred}
        else
          append_reconciled_terminal(run, Shoestring.Elves.Classifier.supervisor_crash(), clock)
        end

      _dispatch ->
        append_reconciled_terminal(run, Shoestring.Elves.Classifier.supervisor_crash(), clock)
    end
  end

  defp within_grace?(updated_at, grace_ms, clock) do
    DateTime.diff(Clock.now(clock), updated_at, :millisecond) < grace_ms
  end

  defp recorded_adapter_verdict(run, repo) do
    query =
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^run.goal_id and event.run_id == ^run.id and
            event.type == "harness.event_recorded",
        order_by: [desc: event.sequence]

    query
    |> repo.all()
    |> Enum.find_value(:none, fn
      %TrajectoryEvent{payload: %{"kind" => "result", "result" => %{"status" => status}}} ->
        {:result, status}

      %TrajectoryEvent{payload: %{"kind" => "error", "error" => error}} when is_map(error) ->
        error_struct(error)

      _event ->
        false
    end)
  end

  defp error_struct(%{"category" => category, "code" => code, "message" => message} = error) do
    {:error,
     Shoestring.Harness.Error.new(
       String.to_existing_atom(category),
       code,
       message,
       details: Map.get(error, "details", %{})
     )}
  rescue
    ArgumentError -> false
  end

  defp error_struct(_error), do: false

  defp append_reconciled_terminal(run, terminal, clock) do
    attrs = %{
      "type" => Shoestring.Elves.Classifier.event_type(terminal),
      "schema_version" => 1,
      "actor" => "elf",
      "occurred_at" => Clock.now(clock),
      "idempotency_key" => "elf-terminal:#{run.dispatch_id}",
      "payload" => Shoestring.Elves.Classifier.event_payload(run.id, terminal)
    }

    case Trajectory.append(run.goal_id, attrs, trusted: [task_id: run.task_id, run_id: run.id]) do
      {:ok, _event} -> {:ok, :reconciled_terminal}
      {:error, reason} -> {:error, reason}
    end
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

  defp continuation_from_run(nil), do: nil

  defp continuation_from_run(%{"checkpoint_id" => checkpoint_id} = continuation) do
    %{
      checkpoint_id: checkpoint_id,
      next_action: Map.get(continuation, "next_action"),
      decision_refs: Map.get(continuation, "decision_refs", [])
    }
  end

  defp continuation_from_run(_continuation), do: nil

  defp capabilities_from_run(%{"items" => items}) when is_list(items) do
    Enum.flat_map(items, fn
      "resume" -> [:resume]
      "send" -> [:send]
      "cancel" -> [:cancel]
      "interactive" -> [:interactive]
      _other -> []
    end)
  end

  defp capabilities_from_run(_capabilities), do: []
end
