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

  alias Shoestring.Harness.{
    Clock,
    Continuation,
    DispatchRecord,
    Dispatches,
    ExecutionLeaseRecord,
    Identity,
    RunIdentity,
    RunRecord,
    RunRequest
  }

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
    dispatch_opts =
      Keyword.take(opts, [
        :repo,
        :clock,
        :identifier,
        :writer_opts,
        :run_id,
        :require_cobbler_command
      ])

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
  Requests stopping at the next safe boundary (after in-flight item/command completion).
  Dispatches to the adapter session's safe stop handler when supported, or returns
  `{:error, :safe_stop_unsupported}` for adapters that cannot honour a safe-boundary stop (e.g. Claude).
  """
  @spec request_stop(Ecto.UUID.t(), keyword()) ::
          {:ok, :stop_requested | :already_terminal} | {:error, term()}
  def request_stop(run_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, run} <- fetch_run(run_id, repo) do
      if terminal_event(run, repo) != nil do
        {:ok, :already_terminal}
      else
        case adapter_for_run(run, opts) do
          adapter when adapter in [:codex, :fake] ->
            dispatch_safe_stop(run, opts)

          _unsupported ->
            {:error, :safe_stop_unsupported}
        end
      end
    end
  end

  defp adapter_for_run(run, opts) do
    case Keyword.get(opts, :adapter) do
      nil -> normalize_adapter(run.provider_id)
      adapter -> normalize_adapter(adapter)
    end
  end

  defp normalize_adapter(Shoestring.Harness.ClaudeHeadless), do: :claude
  defp normalize_adapter("claude_headless_stream_json"), do: :claude
  defp normalize_adapter("claude"), do: :claude
  defp normalize_adapter(:claude), do: :claude

  defp normalize_adapter(Shoestring.Harness.CodexAppServer), do: :codex
  defp normalize_adapter("codex_app_server_stdio"), do: :codex
  defp normalize_adapter("codex"), do: :codex
  defp normalize_adapter(:codex), do: :codex

  defp normalize_adapter(Shoestring.Harness.Fake), do: :fake
  defp normalize_adapter("shoestring.harness.fake"), do: :fake
  defp normalize_adapter("fake"), do: :fake
  defp normalize_adapter(:fake), do: :fake

  defp normalize_adapter(_), do: :unsupported

  defp dispatch_safe_stop(run, opts) do
    session =
      Keyword.get(opts, :session) ||
        Keyword.get(opts, :session_pid) ||
        resolve_session(run.id, opts)

    case session do
      nil ->
        {:error, :session_not_found}

      server ->
        try do
          Shoestring.Harness.CodexAppServer.Session.request_safe_stop(server)
        catch
          :exit, reason -> {:error, {:session_exit, reason}}
        end
    end
  end

  defp resolve_session(run_id, opts) do
    case Keyword.get(opts, :session_resolver) do
      resolver when is_function(resolver, 1) ->
        resolver.(run_id)

      _ ->
        case Shoestring.Harness.CodexAppServer.lookup_session(run_id) do
          {:ok, pid} when is_pid(pid) -> if Process.alive?(pid), do: pid, else: nil
          _ -> nil
        end
    end
  rescue
    _ -> nil
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

  @doc """
  Resumes a run from its latest checkpoint, or hands it to another provider.

  Pipeline (fail-fast, all refusals happen before any adapter call):

    1. project the fresh continuation (`Continuation.for_goal/2`, run-scoped
       with goal fallback; decision refs from `admission.decided` only);
    2. validate the presented continuation (`opts[:continuation]`, defaulting
       to the run's stored continuation) with `Continuation.validate_attrs/1`
       and `Continuation.validate_resume/3`;
    3. when `require_cobbler_command: true` is explicitly passed, authorize
       through `Shoestring.Cobbler.DispatchGate` (read-only; the flag is
       plumbed, never defaulted);
     4. same provider (`opts[:to_provider_id]` defaults to the run's own) →
        `adapter.resume/3` with a rebuilt `RunRequest` carrying the fresh
        continuation (adapters without `resume/3`, e.g. Claude, return
        `:resume_unsupported_for_provider`);
     5. different provider → verify `GoalLifecycle` accepts
        `:handoff_requested` from `opts[:goal_state]` (default `:working`),
        then intent-first: append the `handoff.created` pointer event
        (idempotency key `handoff:<handoff_id>`; replays converge without
        duplicating), create a NEW run of the SAME goal via `Runs.request`,
        and start the target adapter FRESH via `adapter.start/2` with a
        continuation-composed prompt (the sender's session identity is
        never presented to the target).

  Resume is strictly same-run; handoff targets a new run of the same goal
  (cross-goal handoff is out of scope). Live cross-provider handoff is
  UNVERIFIED: hermetic tests cover the Fake-to-Fake path only.
  """
  @spec resume_run(Ecto.UUID.t(), keyword()) ::
          {:ok, RunIdentity.t()}
          | {:ok, %{handoff_id: Ecto.UUID.t(), run: RunRecord.t(), run_identity: RunIdentity.t()}}
          | {:error, term()}
  def resume_run(run_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, run} <- fetch_run(run_id, repo),
         {:ok, fresh_record} <-
           Continuation.latest_checkpoint(repo, run.goal_id, run_id: run.id),
         fresh_refs <- Continuation.decision_refs(repo, run.goal_id),
         {:ok, fresh_cont} <- Continuation.project_latest([fresh_record], fresh_refs),
         {:ok, presented} <- presented_binding(run, opts),
         :ok <- Continuation.validate_attrs(presented_attrs(run, opts)),
         :ok <-
           Continuation.validate_resume(
             presented,
             fresh_binding(fresh_cont, fresh_record),
             resume_context(repo, run, opts)
           ),
         :ok <- maybe_authorize_gate(run.goal_id, opts) do
      case resume_mode(run, opts) do
        :resume -> resume_same_run(run, fresh_cont, opts)
        :handoff -> resume_handoff(run, fresh_cont, fresh_record, opts)
      end
    end
  end

  # -- Resume/handoff private helpers --

  defp presented_attrs(run, opts) do
    case Keyword.get(opts, :continuation) do
      nil -> run_continuation_attrs(run)
      presented when is_map(presented) -> presented
      _other -> :invalid
    end
  end

  defp run_continuation_attrs(%RunRecord{continuation: continuation})
       when is_map(continuation),
       do: continuation

  defp run_continuation_attrs(_run), do: %{}

  defp presented_binding(run, opts) do
    case presented_attrs(run, opts) do
      :invalid ->
        {:error, {:invalid_continuation, :must_be_a_map}}

      attrs ->
        {:ok,
         %{
           checkpoint_id: attrs[:checkpoint_id] || attrs["checkpoint_id"],
           decision_refs: attrs[:decision_refs] || attrs["decision_refs"] || [],
           run_id: run.id,
           provider_session_id: Keyword.get(opts, :provider_session_id, run.provider_session_id)
         }}
    end
  end

  defp fresh_binding(fresh_cont, fresh_record) do
    %{
      checkpoint_id: fresh_cont.checkpoint_id,
      decision_refs: fresh_cont.decision_refs,
      run_id: fresh_record.run_id,
      provider_session_id: fresh_record.provider_session_id
    }
  end

  defp resume_context(repo, run, opts) do
    %{
      mode: resume_mode(run, opts),
      lease_status: latest_lease_status(repo, run.id, opts),
      confirmation_pending: Keyword.get(opts, :confirmation_pending, false),
      adapter_migrates_session: Keyword.get(opts, :adapter_migrates_session, false)
    }
  end

  defp resume_mode(run, opts) do
    if Keyword.get(opts, :to_provider_id, run.provider_id) == run.provider_id do
      :resume
    else
      :handoff
    end
  end

  defp latest_lease_status(repo, run_id, opts) do
    case Keyword.fetch(opts, :lease_status) do
      {:ok, status} ->
        status

      :error ->
        query =
          from lease in ExecutionLeaseRecord,
            where: lease.run_id == ^run_id,
            order_by: [desc: lease.projection_sequence, asc: lease.id],
            limit: 1

        case repo.one(query) do
          %ExecutionLeaseRecord{status: status} -> status
          nil -> :no_lease
        end
    end
  end

  defp latest_lease_id(repo, run_id) do
    query =
      from lease in ExecutionLeaseRecord,
        where: lease.run_id == ^run_id,
        order_by: [desc: lease.projection_sequence, asc: lease.id],
        limit: 1,
        select: lease.id

    repo.one(query)
  end

  defp maybe_authorize_gate(goal_id, opts) do
    if Keyword.get(opts, :require_cobbler_command, false) do
      Shoestring.Cobbler.DispatchGate.authorize(goal_id, repo: Keyword.get(opts, :repo, Repo))
    else
      :ok
    end
  end

  defp resume_same_run(run, fresh_cont, opts) do
    adapter = Keyword.get(opts, :adapter, Shoestring.Harness.Fake)
    adapter_opts = Keyword.get(opts, :adapter_opts, %{})

    with {:ok, request} <- resume_request(run, fresh_cont, run.dispatch_id) do
      invoke_resume(adapter, prior_identity(run, opts), request, adapter_opts)
    end
  end

  # Intent-first handoff (P1): validate -> handoff.created intent ->
  # run.requested -> adapter.start (fresh session, P2). Re-performing with
  # the same handoff_id replays instead of duplicating: the idempotency-key
  # guard runs before any side effect, and the replay decision tree in
  # `replay_stored_receiver/6` decides between success-replay (terminal or
  # live-session evidence) and re-attempt with the same ids (at-least-once
  # with idempotent convergence: the run row, handoff.created, and
  # run.requested all deduplicate by idempotency keys).
  #
  # Writer constraint (recorded deviation from the brief's literal order):
  # the trajectory writer requires a trusted `run_id` to already exist as a
  # goal-owned run row, so the bare run row is inserted just before the
  # handoff.created append. The observable event order is still
  # handoff.created < run.requested < adapter effect, and the guard still
  # precedes everything.
  defp resume_handoff(run, fresh_cont, fresh_record, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    to_provider_id = Keyword.get(opts, :to_provider_id)
    goal_state = Keyword.get(opts, :goal_state, :working)
    handoff_id = Keyword.get(opts, :handoff_id, Ecto.UUID.generate())
    new_dispatch_id = Keyword.get(opts, :new_dispatch_id, Ecto.UUID.generate())
    new_run_id = Keyword.get(opts, :new_run_id, Ecto.UUID.generate())
    reason = Keyword.get(opts, :reason, "provider_handoff")

    with {:ok, :handing_off} <- handoff_transition(goal_state),
         {:ok, payload} <-
           Continuation.handoff_payload(%{
             handoff_id: handoff_id,
             run_id: new_run_id,
             checkpoint_id: fresh_record.id,
             from_provider_id: run.provider_id,
             to_provider_id: to_provider_id,
             contract_version: 1,
             next_action: fresh_cont.next_action,
             decision_refs: fresh_cont.decision_refs,
             reason: reason,
             extensions: %{},
             prior_run_id: run.id,
             lease_grant_id: latest_lease_id(repo, run.id)
           }),
         {:ok, intent} <- check_handoff_intent(repo, run.goal_id, handoff_id) do
      case intent do
        {:replay, event} ->
          case repo.get(RunRecord, event.payload["run_id"] || event.run_id) do
            %RunRecord{} = stored_run ->
              replay_stored_receiver(run, fresh_cont, payload, handoff_id, stored_run, opts)

            nil ->
              # Crash between intent and row insert: continue to exactly one
              # effect, reusing the stored run_id pointer.
              handoff_effect(run, fresh_cont, payload, handoff_id,
                run_id: event.payload["run_id"] || event.run_id,
                dispatch_id: new_dispatch_id,
                opts: opts
              )
          end

        :fresh ->
          handoff_effect(run, fresh_cont, payload, handoff_id,
            run_id: new_run_id,
            dispatch_id: new_dispatch_id,
            opts: opts
          )
      end
    end
  end

  # Idempotency-key guard before any side effect: reports whether a
  # handoff.created intent already exists for this handoff_id. Never
  # appends, inserts, or calls the adapter.
  defp check_handoff_intent(repo, goal_id, handoff_id) do
    key = "handoff:" <> handoff_id

    case repo.one(
           from event in TrajectoryEvent,
             where:
               event.goal_id == ^goal_id and event.type == "handoff.created" and
                 event.idempotency_key == ^key,
             order_by: [asc: event.sequence],
             limit: 1
         ) do
      %TrajectoryEvent{} = event -> {:ok, {:replay, event}}
      nil -> {:ok, :fresh}
    end
  end

  # Replay decision tree (round-2 finding 5): the receiver run row existing
  # is NOT success. The row is inserted before the adapter effect, so a
  # crash (or failed start) between row insert and adapter start would
  # otherwise replay to success with the receiver never started. On replay
  # with the receiver row present:
  #
  #   1. terminal/result evidence for the new run -> success-replay, zero
  #      new calls (the effect demonstrably completed downstream);
  #   2. else a live receiver session observable via the adapter's
  #      `lookup_session/1` (where supported, e.g. CodexAppServer) ->
  #      success with that identity, zero new calls;
  #   3. else re-attempt the effect with the SAME handoff/run/dispatch ids
  #      (at-least-once with idempotent convergence: first genuine success
  #      wins; duplicates impossible by idempotency keys).
  #
  # Fake exposes no `lookup_session/1`, so Fake replays re-attempt whenever
  # no terminal/result evidence exists.
  defp replay_stored_receiver(run, fresh_cont, payload, handoff_id, stored_run, opts) do
    adapter = Keyword.get(opts, :adapter, Shoestring.Harness.Fake)
    repo = Keyword.get(opts, :repo, Repo)

    cond do
      receiver_terminal?(repo, stored_run) ->
        {:ok,
         %{
           handoff_id: handoff_id,
           run: stored_run,
           run_identity: replay_identity(stored_run)
         }}

      live_receiver_session?(adapter, stored_run) ->
        {:ok,
         %{
           handoff_id: handoff_id,
           run: stored_run,
           run_identity: replay_identity(stored_run)
         }}

      true ->
        # No evidence the effect ever ran: re-attempt it with the SAME
        # handoff/run/dispatch ids. The receiver row already exists, so the
        # re-attempt converges through the idempotent event appends plus a
        # fresh adapter.start (a blind row re-insert would collide on the
        # primary key instead of converging).
        adapter = Keyword.get(opts, :adapter, Shoestring.Harness.Fake)

        with {:ok, request} <- handoff_request(run, fresh_cont, stored_run.dispatch_id),
             {:ok, identity} <- adapter_identity(adapter) do
          run_handoff_effect(run, stored_run, request, identity, payload, handoff_id, opts)
        end
    end
  end

  # Terminal/result evidence for the receiver run: a run terminal
  # (`run.completed` / `run.failed` / `run.interrupted` / `run.cancelled`)
  # or a recorded harness result (`harness.event_recorded` with kind
  # `result`). `run.requested` deliberately does NOT count: it is appended
  # before the adapter effect, so it cannot prove the effect ran.
  defp receiver_terminal?(repo, %RunRecord{} = stored_run) do
    terminal? =
      repo.exists?(
        from event in TrajectoryEvent,
          where:
            event.goal_id == ^stored_run.goal_id and event.run_id == ^stored_run.id and
              event.type in ["run.completed", "run.failed", "run.interrupted", "run.cancelled"]
      )

    result? =
      repo.exists?(
        from event in TrajectoryEvent,
          where:
            event.goal_id == ^stored_run.goal_id and event.run_id == ^stored_run.id and
              event.type == "harness.event_recorded" and
              fragment("(? ->> ?) = ?", event.payload, "kind", "result")
      )

    terminal? or result?
  end

  # Live-session read only: never starts, probes, or mutates session state,
  # and never touches session turn logic. Adapters without
  # `lookup_session/1` (e.g. Fake) report no live session.
  defp live_receiver_session?(adapter, %RunRecord{} = stored_run) do
    if adapter_exports?(adapter, :lookup_session, 1) do
      case apply(adapter, :lookup_session, [stored_run.id]) do
        {:ok, pid} when is_pid(pid) -> Process.alive?(pid)
        _other -> false
      end
    else
      false
    end
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  # Single effect path: bare run row (writer trusted-reference requirement)
  # -> handoff.created intent -> run.requested durable effect ->
  # adapter.start fresh session. The sender's session identity is never
  # presented to the target.
  defp handoff_effect(run, fresh_cont, payload, handoff_id,
         run_id: run_id,
         dispatch_id: dispatch_id,
         opts: opts
       ) do
    repo = Keyword.get(opts, :repo, Repo)
    clock = Keyword.get(opts, :clock, Shoestring.Harness.SystemClock)
    adapter = Keyword.get(opts, :adapter, Shoestring.Harness.Fake)

    with {:ok, request} <- handoff_request(run, fresh_cont, dispatch_id),
         {:ok, identity} <- adapter_identity(adapter),
         {:ok, changeset} <-
           Shoestring.Harness.Runs.build_intent_changeset(request, identity,
             repo: repo,
             clock: clock,
             run_id: run_id
           ),
         {:ok, new_run} <- Shoestring.Harness.Runs.insert_or_recover(repo, changeset) do
      run_handoff_effect(run, new_run, request, identity, payload, handoff_id, opts)
    end
  end

  # Effect tail for an already-persisted receiver row: idempotent
  # handoff.created + run.requested appends (duplicates converge by
  # idempotency key), then the adapter.start fresh session. Used by
  # `handoff_effect/6` after the row insert and directly by replay
  # re-attempts, where the row already exists.
  defp run_handoff_effect(run, new_run, request, identity, payload, handoff_id, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    clock = Keyword.get(opts, :clock, Shoestring.Harness.SystemClock)
    adapter = Keyword.get(opts, :adapter, Shoestring.Harness.Fake)
    adapter_opts = Keyword.get(opts, :adapter_opts, %{})

    with {:ok, _event} <- append_handoff_created(run, new_run.id, payload, handoff_id, opts),
         :ok <-
           Shoestring.Harness.Runs.ensure_requested_event(new_run, request, identity,
             repo: repo,
             clock: clock,
             writer_opts: Keyword.get(opts, :writer_opts, [])
           ),
         {:ok, run_identity} <- invoke_start(adapter, request, adapter_opts) do
      {:ok, %{handoff_id: handoff_id, run: new_run, run_identity: run_identity}}
    end
  end

  defp append_handoff_created(run, new_run_id, payload, handoff_id, opts) do
    clock = Keyword.get(opts, :clock, Shoestring.Harness.SystemClock)

    Trajectory.append(
      run.goal_id,
      %{
        "type" => "handoff.created",
        "schema_version" => 1,
        "actor" => "elf",
        "occurred_at" => Clock.now(clock),
        "idempotency_key" => "handoff:" <> handoff_id,
        "payload" => payload
      },
      trusted: [task_id: run.task_id, run_id: new_run_id],
      writer_opts: Keyword.get(opts, :writer_opts, [])
    )
  end

  defp replay_identity(%RunRecord{} = stored_run) do
    case RunIdentity.new(%{
           run_id: stored_run.id,
           harness_id: stored_run.provider_id,
           process_id: nil,
           provider_session_id: stored_run.provider_session_id
         }) do
      {:ok, identity} ->
        identity

      {:error, _} ->
        %RunIdentity{
          run_id: stored_run.id,
          harness_id: stored_run.provider_id,
          process_id: nil,
          provider_session_id: stored_run.provider_session_id
        }
    end
  end

  # Cross-provider handoff request (P2): a FRESH session whose prompt is
  # composed from the continuation (checkpoint pointer + next_action +
  # decision refs + constraints summary, bounded, transcript-free). The
  # sender's original prompt and session identity are never carried over.
  defp handoff_request(run, fresh_cont, dispatch_id) do
    attrs = %{
      version: 1,
      goal_id: run.goal_id,
      task_id: run.task_id,
      workspace_ref: run.workspace_ref,
      prompt: Continuation.compose_handoff_prompt(fresh_cont),
      continuation: %{
        checkpoint_id: fresh_cont.checkpoint_id,
        next_action: fresh_cont.next_action,
        decision_refs: fresh_cont.decision_refs
      },
      policy: run.policy || %{mode: "supervised"},
      requested_capabilities: resume_capabilities(run),
      dispatch_id: dispatch_id,
      extensions: run.extensions || %{}
    }

    case RunRequest.new(attrs) do
      {:ok, request} -> {:ok, request}
      {:error, changeset} -> {:error, {:invalid_resume_request, changeset}}
    end
  end

  # Fresh-session effect for handoff targets (P2): adapter.start, never
  # resume. The sender's RunIdentity is never constructed for the target.
  defp invoke_start(adapter, request, adapter_opts) do
    if adapter_exports?(adapter, :start, 2) do
      adapter.start(request, adapter_opts)
    else
      {:error, :handoff_start_unsupported}
    end
  end

  defp handoff_transition(goal_state) do
    case Shoestring.Cobbler.GoalLifecycle.transition(goal_state, :handoff_requested) do
      {:ok, :handing_off} -> {:ok, :handing_off}
      {:error, reason} -> {:error, {:handoff_not_allowed, reason}}
    end
  end

  defp adapter_identity(adapter) do
    case adapter.identity() do
      %Identity{} = identity -> {:ok, identity}
      {:ok, %Identity{} = identity} -> {:ok, identity}
      _other -> {:error, :adapter_identity_unavailable}
    end
  rescue
    _error -> {:error, :adapter_identity_unavailable}
  end

  # Same-provider resume without a resume/3 (e.g. Claude) is impossible
  # (P5): a precise error, never a fake resume. Cross-provider targets go
  # through invoke_start/3 instead and never reach this path.
  #
  # The module is explicitly loaded first: `function_exported?/3` does not
  # load unloaded modules, so without this the first resume call in a fresh
  # VM would spuriously report unsupported.
  defp invoke_resume(adapter, prior, request, adapter_opts) do
    if adapter_exports?(adapter, :resume, 3) do
      adapter.resume(prior, request, adapter_opts)
    else
      {:error, :resume_unsupported_for_provider}
    end
  end

  defp adapter_exports?(adapter, fun, arity) when is_atom(adapter) do
    case Code.ensure_loaded(adapter) do
      {:module, _} -> function_exported?(adapter, fun, arity)
      {:error, _} -> false
    end
  end

  defp adapter_exports?(_adapter, _fun, _arity), do: false

  defp prior_identity(run, opts) do
    %RunIdentity{
      run_id: run.id,
      harness_id: run.provider_id,
      process_id: nil,
      provider_session_id: Keyword.get(opts, :provider_session_id, run.provider_session_id)
    }
  end

  defp resume_request(run, continuation, dispatch_id) do
    attrs = %{
      version: 1,
      goal_id: run.goal_id,
      task_id: run.task_id,
      workspace_ref: run.workspace_ref,
      prompt: run.prompt,
      continuation: %{
        checkpoint_id: continuation.checkpoint_id,
        next_action: continuation.next_action,
        decision_refs: continuation.decision_refs
      },
      policy: run.policy || %{mode: "supervised"},
      requested_capabilities: resume_capabilities(run),
      dispatch_id: dispatch_id,
      extensions: run.extensions || %{}
    }

    case RunRequest.new(attrs) do
      {:ok, request} -> {:ok, request}
      {:error, changeset} -> {:error, {:invalid_resume_request, changeset}}
    end
  end

  # Twin of `capabilities_from_run/1` (Oban effect path): string items back
  # to capability atoms, dropping anything unrecognized.
  defp resume_capabilities(%RunRecord{requested_capabilities: %{"items" => items}})
       when is_list(items) do
    Enum.flat_map(items, fn
      "resume" -> [:resume]
      "send" -> [:send]
      "cancel" -> [:cancel]
      "interactive" -> [:interactive]
      _other -> []
    end)
  end

  defp resume_capabilities(_run), do: []

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
      process_owner: Keyword.get(opts, :process_owner, :runner),
      command: Keyword.get(opts, :command, ["sleep", "30"]),
      env: Keyword.get(opts, :env, []),
      runner_opts: Keyword.get(opts, :runner_opts, default_runner_opts()),
      event_interval_ms: Keyword.get(opts, :event_interval_ms, 0),
      adapter_poll_ms: Keyword.get(opts, :adapter_poll_ms, 25),
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
            event.type in ["run.completed", "run.failed", "run.interrupted", "run.cancelled"],
        order_by: [desc: event.sequence],
        limit: 1

    case repo.one(query) do
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

  # If the Elf vanishes between lookup and call, fall back to terminating
  # the recorded group directly so cancellation still lands.
  defp cancel_via_elf(run, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    case Elf.cancel(whereis(run.id), timeout: timeout) do
      {:ok, :cancelled} -> {:ok, :cancelled}
      {:ok, :already_terminal} -> {:ok, :already_terminal}
      {:error, _reason} -> cancel_without_elf(run, opts)
    end
  catch
    :exit, _reason -> cancel_without_elf(run, opts)
  end

  defp cancel_without_elf(run, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    clock = Keyword.get(opts, :clock, Shoestring.Harness.SystemClock)

    if terminal_event(run, repo) != nil do
      {:ok, :already_terminal}
    else
      _ = terminate_recorded_group(run, repo, opts)

      with {:ok, :cancelled} <- append_cancelled(run, clock) do
        # Read back what actually won the terminal race: a concurrent natural
        # terminal keeps its single-terminal guarantee via the shared
        # idempotency key, and the return value reports it honestly.
        case terminal_event(run, repo) do
          %{class: :cancelled} -> {:ok, :cancelled}
          _other -> {:ok, :already_terminal}
        end
      end
    end
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

  defp append_cancelled(run, clock) do
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
