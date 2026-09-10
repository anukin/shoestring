defmodule Shoestring.Cobbler.Wakeups do
  @moduledoc """
  Durable wake intents for sleeping Cobbler goals (Milestone 05, work package E).

  A sleeping goal wakes only on an explicit, durable signal: a `cobbler_wakeups`
  row plus an Oban `wakeup`-queue delivery attempt sharing one idempotency
  key. Rows are effect truth; jobs are delivery attempts. The worker marks a
  row `woken` only after its branch writes commit, and re-performing a `woken`
  row is a no-op.

  Idempotency keys derive from durable identity only (P2):

  - `"wakeup:<goal_id>:<command_id>"` for command-pinned wakes,
  - `"wakeup:<goal_id>:<decision_id>:<defer_until>"` for deferral wakes,
  - `"wakeup:<goal_id>:manual:<operator_identity>"` (plus a durable
    `":r<N>"` suffix when a terminal row already holds the base key) for
    operator rechecks.

  The `":r<N>"` suffix is derived from durable row state (the count of rows
  already holding the base key), never from wall-clock time or randomness.

  Wake-to-reobserve (§P4, `perform_wakeup/2`) runs a fixed order: fresh
  snapshot scoped to the run/decision provider/scope (persisted as
  `capacity.snapshot_observed`; a probe failure leaves the intent due and
  stops) → `AdmissionEvaluation.evaluate/5` with an explicit `now` plus
  claim occupancy → branch:

  - `:admit` → renew (when a renewable lease exists) + resume
    (`GoalLifecycle` sleeping → evaluating → queued; lease
    `renewal_due → renewed` chained to the fresh snapshot; run
    `suspended → starting` via `run.starting`) + dispatch one continuation
    through the durable `Dispatches.enqueue/3` pipeline (never direct
    `Elves.start_run/3`). The continuation is a NEW run of the same
    goal+task carrying the resumed run's workspace, prompt, policy, and
    capabilities; its `dispatch_id` is the wakeup row id, so a crash
    between enqueue and the `woken` mark re-performs into
    `Runs.recover_existing_run/2` + `ensure_delivery/2` (one dispatch
    record, one job). Enqueue passes `require_cobbler_command: true`, so
    the live claim trajectory still authorizes the dispatch — an admit
    without the claim fails closed and the intent stays due. Without a run
    there is nothing to continue and dispatch stays `:gated`: the goal
    still reaches queued and waits for the claim flow.
  - `:defer_until` → expire (+ `checkpoint_required`) + checkpoint contents
    (via the deterministic `CheckpointFallback` template and the
    `Checkpoints` writer) + resleep with the evaluation's new `wake_at`
    (the run stays suspended).
  - `:require_confirmation` → stay asleep. The P5 `GoalLifecycle` clauses
    keep `sleeping + require_confirmation` a legal wait (instead of
    collapsing derivation to `:unknown`), so the existing operator surface
    (`Commands.pending/2` plus the recorded decision) keeps rendering the
    sleeping goal with its confirmation CTA. The next wake comes from an
    explicit operator `request_recheck/2`.
  - `:reject` → `handing_off` + cancel intents (sibling pending wakeups are
    cancelled; a suspended run is moved to `cancelled`).

  Oban `scheduled_at` is durable delivery, never a trigger: the worker still
  re-observes before acting, per the locked iteration-4 decisions. No timer,
  no backfill, no truncation of oversized output (oversized checkpoint inputs
  hard-fail in `CheckpointFallback`).
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Oban.Job

  alias Shoestring.Cobbler.{
    AdmissionDecision,
    AdmissionEvaluation,
    AdmissionPolicy,
    Commands,
    GoalLifecycle,
    Leases,
    WakeupRecord,
    WakeupWorker
  }

  alias Shoestring.Harness.{
    CapacitySnapshot,
    CheckpointFallback,
    Checkpoints,
    ClaudeHeadless,
    Clock,
    CodexAppServer,
    Continuation,
    Dispatches,
    EventPayload,
    ExecutionLease,
    ExecutionLeaseRecord,
    Fake,
    Projector,
    RunRecord,
    RunRequest
  }

  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{Goal, TrajectoryEvent}

  @actor "cobbler"
  @schema_version 1
  @live_job_states ["available", "scheduled", "executing", "retryable", "suspended"]
  @terminal_goal_statuses ["completed", "archived"]
  @renewable_lease_statuses ["active", "renewal_due"]

  @type schedule_result :: %{
          required(:wakeup) => WakeupRecord.t(),
          required(:outcome) => :recorded | :replayed,
          required(:job) => Job.t() | nil
        }

  # ----------------------------------------------------------------------------
  # Scheduling
  # ----------------------------------------------------------------------------

  @doc """
  Schedules a durable wake intent for a goal.

  Identity (P2): pass `:command_id` **or** `:decision_id` plus `:defer_until`
  (`%DateTime{}` or ISO8601). Manual rechecks pass `:manual_operator`
  instead. `:wake_at` defaults to `defer_until` (or `now`); `:reason`
  defaults per path; `:run_id` and `:command_id` are recorded on the row;
  `:request` / `:candidate` / `:decision_event_id` travel in the Oban job
  args as admission context.

  Returns `{:ok, %{wakeup:, outcome: :recorded | :replayed, job:}}`. A
  pending row under the same key replays with no new effects. A terminal
  goal refuses with `{:error, {:wakeup_rejected, :goal_terminal}}`.

  Options: `:repo`, `:now`, `:clock`, `:writer_opts` (unused here, accepted
  for symmetry), `:reason`, `:wake_at`, `:run_id`, `:command_id`,
  `:decision_id`, `:defer_until`, `:manual_operator`, `:request`,
  `:candidate`, `:decision_event_id`.
  """
  @spec schedule(Ecto.UUID.t(), keyword()) :: {:ok, schedule_result()} | {:error, term()}
  def schedule(goal_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, goal_id} <- cast_goal_id(goal_id),
         {:ok, _goal} <- live_goal(repo, goal_id),
         {:ok, key} <- idempotency_key(goal_id, opts),
         {:ok, now} <- resolve_now(opts),
         {:ok, wake_at} <- wake_at(opts, now),
         {:ok, status} <- status_for(wake_at, now) do
      insert_or_replay(repo, goal_id, key, wake_at, status, now, opts)
    end
  end

  defp insert_or_replay(repo, goal_id, key, wake_at, status, now, opts, attempts \\ 3)

  defp insert_or_replay(_repo, _goal_id, _key, _wake_at, _status, _now, _opts, 0),
    do: {:error, :wakeup_identity_exhausted}

  defp insert_or_replay(repo, goal_id, key, wake_at, status, now, opts, attempts) do
    case repo.get_by(WakeupRecord, idempotency_key: key) do
      %WakeupRecord{status: status} = existing when status in ["scheduled", "due"] ->
        {:ok, %{wakeup: existing, outcome: :replayed, job: nil}}

      %WakeupRecord{} ->
        suffixed = suffixed_key(repo, key)
        insert_or_replay(repo, goal_id, suffixed, wake_at, status, now, opts, attempts - 1)

      nil ->
        insert_wakeup(repo, goal_id, key, wake_at, status, now, opts)
    end
  end

  defp insert_wakeup(repo, goal_id, key, wake_at, status, now, opts) do
    attrs = %{
      goal_id: goal_id,
      run_id: Keyword.get(opts, :run_id),
      command_id: Keyword.get(opts, :command_id),
      wake_at: wake_at,
      reason: Keyword.get(opts, :reason, default_reason(opts)),
      status: status,
      idempotency_key: key,
      inserted_at: now,
      updated_at: now
    }

    Multi.new()
    |> Multi.insert(:wakeup, WakeupRecord.changeset(%WakeupRecord{}, attrs))
    |> Oban.insert(:job, fn %{wakeup: wakeup} -> job_changeset(wakeup, key, opts) end)
    |> repo.transaction()
    |> case do
      {:ok, %{wakeup: wakeup, job: job}} ->
        {:ok, %{wakeup: wakeup, outcome: :recorded, job: job}}

      {:error, :wakeup, changeset, _changes} ->
        if unique_conflict?(changeset, :idempotency_key) do
          case repo.get_by(WakeupRecord, idempotency_key: key) do
            %WakeupRecord{status: status} = existing when status in ["scheduled", "due"] ->
              {:ok, %{wakeup: existing, outcome: :replayed, job: nil}}

            %WakeupRecord{} ->
              suffixed = suffixed_key(repo, key)

              insert_or_replay(repo, goal_id, suffixed, wake_at, status, now, opts)

            nil ->
              {:error, changeset}
          end
        else
          {:error, changeset}
        end

      {:error, :job, _changeset, _changes} ->
        case repo.get_by(WakeupRecord, idempotency_key: key) do
          %WakeupRecord{} = existing ->
            {:ok, %{wakeup: existing, outcome: :replayed, job: nil}}

          nil ->
            {:error, :wakeup_job_conflict}
        end

      {:error, _operation, reason, _changes} ->
        {:error, reason}
    end
  end

  defp job_changeset(wakeup, key, opts) do
    args =
      %{
        "wakeup_id" => wakeup.id,
        "goal_id" => wakeup.goal_id,
        "idempotency_key" => key
      }
      |> maybe_put("request", Keyword.get(opts, :request))
      |> maybe_put("candidate", Keyword.get(opts, :candidate))
      |> maybe_put("decision_event_id", Keyword.get(opts, :decision_event_id))

    WakeupWorker.new(args, scheduled_at: wakeup.wake_at)
  end

  # ----------------------------------------------------------------------------
  # Startup reconcile
  # ----------------------------------------------------------------------------

  @doc """
  Repairs durable wake intents without adding new wake semantics.

  For every `scheduled`/`due` row, in `wake_at` order: terminal goals have
  their rows cancelled; `scheduled` rows past `wake_at` flip to `due`;
  rows without a live Oban delivery attempt get one re-enqueued (Oban
  uniqueness on the idempotency key makes the re-enqueue dupe-safe even if
  the live-job lookup ever misses).

  Returns `{:ok, %{repaired_count:, failures:}}` with sanitized failure
  reasons, mirroring `Dispatches.reconcile/1`.
  """
  @spec reconcile(keyword()) ::
          {:ok, %{repaired_count: non_neg_integer(), failures: [map()]}} | {:error, term()}
  def reconcile(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, now} <- resolve_now(opts) do
      wakeups =
        repo.all(
          from wakeup in WakeupRecord,
            where: wakeup.status in ["scheduled", "due"],
            order_by: [asc: wakeup.wake_at, asc: wakeup.id]
        )

      result =
        Enum.reduce(wakeups, %{repaired_count: 0, failures: []}, fn wakeup, acc ->
          case safe_repair_wakeup(repo, wakeup, now, opts) do
            {:ok, repaired} ->
              %{acc | repaired_count: acc.repaired_count + repaired}

            {:error, reason} ->
              %{acc | failures: acc.failures ++ [reconcile_failure(wakeup, reason)]}
          end
        end)

      emit_reconcile(result)
      {:ok, result}
    end
  end

  defp safe_repair_wakeup(repo, wakeup, now, opts) do
    try do
      repair_wakeup(repo, wakeup, now, opts)
    rescue
      _error -> {:error, :reconciliation_failed}
    catch
      _kind, _reason -> {:error, :reconciliation_failed}
    end
  end

  defp repair_wakeup(repo, wakeup, now, opts) do
    case repo.get(Goal, wakeup.goal_id) do
      %Goal{status: status} when status in @terminal_goal_statuses ->
        {:ok, _} = mark_status(repo, wakeup, "cancelled", now)
        {:ok, 1}

      %Goal{} ->
        with {:ok, flipped} <- maybe_flip_due(repo, wakeup, now),
             {:ok, requeued} <- maybe_requeue(repo, wakeup, opts) do
          {:ok, flipped + requeued}
        end

      nil ->
        {:ok, _} = mark_status(repo, wakeup, "cancelled", now)
        {:ok, 1}
    end
  end

  defp maybe_flip_due(repo, %WakeupRecord{status: "scheduled", wake_at: wake_at} = wakeup, now) do
    if DateTime.compare(wake_at, now) != :gt do
      {:ok, _} = mark_status(repo, wakeup, "due", now)
      {:ok, 1}
    else
      {:ok, 0}
    end
  end

  defp maybe_flip_due(_repo, _wakeup, _now), do: {:ok, 0}

  defp maybe_requeue(repo, wakeup, _opts) do
    if live_job?(repo, wakeup) do
      {:ok, 0}
    else
      args = %{
        "wakeup_id" => wakeup.id,
        "goal_id" => wakeup.goal_id,
        "idempotency_key" => wakeup.idempotency_key
      }

      case WakeupWorker.new(args, scheduled_at: wakeup.wake_at) |> Oban.insert(repo: repo) do
        {:ok, _job} -> {:ok, 1}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp live_job?(repo, wakeup) do
    states = @live_job_states
    wakeup_id = wakeup.id

    repo.exists?(
      from job in Job,
        where:
          job.state in ^states and
            fragment("json_extract(?, '$.wakeup_id') = ?", job.args, ^wakeup_id)
    )
  rescue
    _error -> false
  end

  # ----------------------------------------------------------------------------
  # Manual operator recheck
  # ----------------------------------------------------------------------------

  @doc """
  Schedules an immediate operator wake for a goal.

  Requires an explicit operator identity (`:operator_identity`): anonymous
  calls return `{:error, :anonymous_operator}`. Terminal goals and goals
  whose derived lifecycle state is `:handing_off` are rejected with
  `{:error, {:recheck_rejected, reason}}` instead of scheduling.

  Admission context resolves from `:request`/`:candidate` opts, else from
  the goal's latest `admission.decided` event (`{:error, :no_prior_decision}`
  when none exists). Accepts the `schedule/2` delivery opts plus
  `:operator_identity` (required), `:run_id`, `:reason` (default
  `"manual_recheck"`).
  """
  @spec request_recheck(Ecto.UUID.t(), keyword()) ::
          {:ok, schedule_result()} | {:error, term()}
  def request_recheck(goal_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, goal_id} <- cast_goal_id(goal_id),
         {:ok, operator} <- operator_identity(opts),
         {:ok, _goal} <- live_goal(repo, goal_id),
         :ok <- reject_handing_off(repo, goal_id),
         {:ok, {request, candidate}} <- recheck_context(repo, goal_id, opts),
         {:ok, now} <- resolve_now(opts) do
      schedule(
        goal_id,
        opts
        |> Keyword.put(:manual_operator, operator)
        |> Keyword.put(:request, request)
        |> Keyword.put(:candidate, candidate)
        |> Keyword.put_new(:reason, "manual_recheck")
        |> Keyword.put_new(:wake_at, now)
      )
    end
  end

  defp operator_identity(opts) do
    case Keyword.get(opts, :operator_identity) do
      value when is_binary(value) ->
        if String.trim(value) == "" do
          {:error, :anonymous_operator}
        else
          {:ok, value}
        end

      _other ->
        {:error, :anonymous_operator}
    end
  end

  defp reject_handing_off(repo, goal_id) do
    case lifecycle_state(repo, goal_id) do
      :handing_off -> {:error, {:recheck_rejected, :handing_off}}
      :unknown -> {:error, {:recheck_rejected, :unknown_state}}
      _state -> :ok
    end
  end

  defp recheck_context(repo, goal_id, opts) do
    request = Keyword.get(opts, :request)
    candidate = Keyword.get(opts, :candidate)

    if is_map(request) and is_map(candidate) do
      {:ok, {request, candidate}}
    else
      case latest_decision(repo, goal_id) do
        {:ok, decision} ->
          {:ok, {context_request(goal_id, nil, decision), context_candidate(decision)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Derives the presentational goal lifecycle state by folding the goal's
  `admission.decided` results and persisted command result kinds through the
  pure `GoalLifecycle` machine (mirroring the web derivation). Illegal
  transitions and unknown values fold to `:unknown`; this function never
  raises.
  """
  @spec lifecycle_state(module(), Ecto.UUID.t()) :: atom()
  def lifecycle_state(repo \\ Repo, goal_id) do
    decisions =
      repo.all(
        from event in TrajectoryEvent,
          where: event.goal_id == ^goal_id and event.type == "admission.decided",
          order_by: [asc: event.sequence],
          select: event.payload
      )
      |> Enum.map(& &1["result"])

    kinds =
      repo.all(
        from command in Shoestring.Cobbler.CommandRecord,
          where: command.goal_id == ^goal_id,
          order_by: [asc: command.inserted_at, asc: command.id],
          select: command.result
      )
      |> Enum.map(& &1["kind"])

    events =
      Enum.map(decisions, &{:admission_decision, &1}) ++
        Enum.map(kinds, &{:command_outcome, &1})

    Enum.reduce_while(events, GoalLifecycle.initial(), fn event, state ->
      case safe_lifecycle(state, event) do
        {:ok, next} -> {:cont, next}
        :unknown -> {:halt, :unknown}
      end
    end)
  rescue
    _error -> :unknown
  end

  defp safe_lifecycle(state, {:admission_decision, result}) do
    with {:ok, event} <- GoalLifecycle.decision_event(normalize_result(result)),
         {:ok, next} <- GoalLifecycle.transition(state, event) do
      {:ok, next}
    else
      _error -> :unknown
    end
  rescue
    _error -> :unknown
  end

  defp safe_lifecycle(state, {:command_outcome, kind}) do
    with {:ok, outcome} <- normalize_outcome(kind),
         {:ok, next} <- GoalLifecycle.transition(state, {:command_outcome, outcome}) do
      {:ok, next}
    else
      _error -> :unknown
    end
  rescue
    _error -> :unknown
  end

  defp normalize_result(result) when is_atom(result), do: result

  defp normalize_result(result) when is_binary(result) do
    String.to_existing_atom(result)
  rescue
    ArgumentError -> :__unknown_result__
  end

  defp normalize_result(_result), do: :__unknown_result__

  defp normalize_outcome(kind) when is_atom(kind), do: normalize_outcome(Atom.to_string(kind))

  defp normalize_outcome(kind) when is_binary(kind) do
    try do
      outcome = String.to_existing_atom(kind)

      if outcome in [:claimed, :needs_user, :rejected, :released, :no_active_claim, :abandoned] do
        {:ok, outcome}
      else
        :error
      end
    rescue
      ArgumentError -> :error
    end
  end

  defp normalize_outcome(_kind), do: :error

  # ----------------------------------------------------------------------------
  # Wake-to-reobserve orchestration
  # ----------------------------------------------------------------------------

  @doc """
  Performs one durable wake: fresh snapshot → re-evaluate → branch.

  Returns `{:ok, summary}` where `summary.branch` is one of `:admitted`,
  `:deferred`, `:require_confirmation`, `:rejected`, `:goal_terminal`,
  `:already_woken`, or `:already_cancelled`. Observation or evaluation
  failures return `{:error, reason}` and leave the intent due.

  Options: `:repo`, `:now`, `:clock`, `:observe` (required fun returning
  `{:ok, CapacitySnapshot.t()} | {:error, reason}` — arity 1 scoped, called
  with `%{provider_id:, scope:}` derived from the run/decision candidate, or
  arity 0 legacy whose result is still binding-checked downstream),
  `:occupancy` (default: derived from the live global claim), `:policy`,
  `:request`, `:candidate`, `:decision_event_id`, `:actor` (default
  `"cobbler"`), `:identity` (explicit dispatch-identity override; default
  resolves from the suspended run's provider — production wakes never fall
  back to a Fake identity), `:writer_opts`, `:checkpoint_criteria`,
  `:repository_revision`.
  """
  @spec perform_wakeup(Ecto.UUID.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def perform_wakeup(wakeup_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, wakeup} <- fetch_wakeup(repo, wakeup_id),
         :ok <- actionable_wakeup(wakeup),
         {:ok, now} <- resolve_now(opts),
         {:ok, goal} <- fetch_goal(repo, wakeup.goal_id),
         :ok <- live_wakeup_goal(repo, wakeup, goal, now),
         {:ok, run} <- fetch_run(repo, wakeup),
         {:ok, lease} <- latest_lease(repo, run),
         {:ok, {request, candidate}} <- admission_context(repo, wakeup, goal, run, opts),
         {:ok, snapshot} <- observe(opts, candidate),
         {:ok, _snapshot_event} <- persist_snapshot(wakeup, goal, run, snapshot, now, opts),
         {:ok, _position} <- Projector.project(goal.id, clock: clock(opts)),
         {:ok, evaluation} <- evaluate(repo, goal, snapshot, request, candidate, now, opts) do
      branch(repo, wakeup, goal, run, lease, snapshot, evaluation, now, opts)
    else
      {:noop, summary} -> {:ok, summary}
      {:terminal, summary} -> {:ok, summary}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_wakeup(repo, wakeup_id) do
    case repo.get(WakeupRecord, wakeup_id) do
      %WakeupRecord{} = wakeup -> {:ok, wakeup}
      nil -> {:error, :wakeup_not_found}
    end
  end

  # Actionable rows return `:ok`; terminal rows short-circuit the `with`
  # chain with an explicit `{:noop, summary}` / `{:terminal, summary}` tag.
  defp actionable_wakeup(%WakeupRecord{status: "woken", id: id}),
    do: {:noop, %{outcome: :already_woken, wakeup_id: id, branch: :already_woken}}

  defp actionable_wakeup(%WakeupRecord{status: "cancelled", id: id}),
    do: {:noop, %{outcome: :already_cancelled, wakeup_id: id, branch: :already_cancelled}}

  defp actionable_wakeup(%WakeupRecord{status: status})
       when status in ["scheduled", "due"],
       do: :ok

  defp fetch_goal(repo, goal_id) do
    case repo.get(Goal, goal_id) do
      %Goal{} = goal -> {:ok, goal}
      nil -> {:error, :goal_not_found}
    end
  end

  defp live_wakeup_goal(repo, wakeup, goal, now) do
    if goal.status in @terminal_goal_statuses do
      {:ok, _} = mark_status(repo, wakeup, "cancelled", now)
      {:terminal, %{outcome: :goal_terminal, wakeup_id: wakeup.id, branch: :goal_terminal}}
    else
      :ok
    end
  end

  defp fetch_run(_repo, %WakeupRecord{run_id: nil}), do: {:ok, nil}

  defp fetch_run(repo, %WakeupRecord{run_id: run_id, goal_id: goal_id}) do
    case repo.get_by(RunRecord, id: run_id, goal_id: goal_id) do
      %RunRecord{} = run -> {:ok, run}
      nil -> {:error, {:run_not_found, run_id}}
    end
  end

  defp latest_lease(_repo, nil), do: {:ok, nil}

  defp latest_lease(repo, %RunRecord{id: run_id}) do
    lease =
      repo.one(
        from lease in ExecutionLeaseRecord,
          where: lease.run_id == ^run_id,
          order_by: [desc: lease.inserted_at, desc: lease.id],
          limit: 1
      )

    {:ok, lease}
  end

  # Admission context resolves BEFORE the fresh observation so the probe
  # is scoped to the run/decision provider/scope (W1): a wake admission for
  # one provider must never be decided on another provider's allowance.
  defp observe(opts, candidate) do
    scoping = observe_scoping(candidate)

    result =
      case Keyword.fetch(opts, :observe) do
        {:ok, observe_fun} when is_function(observe_fun, 1) -> observe_fun.(scoping)
        {:ok, observe_fun} when is_function(observe_fun, 0) -> observe_fun.()
        _missing -> {:error, :missing_observe_fun}
      end

    case result do
      {:ok, %CapacitySnapshot{} = snapshot} -> {:ok, snapshot}
      {:error, reason} -> {:error, {:observation_failed, reason}}
      _other -> {:error, {:observation_failed, :unexpected_observe_result}}
    end
  end

  defp observe_scoping(candidate) when is_map(candidate) do
    %{
      provider_id: Map.get(candidate, :provider_id, Map.get(candidate, "provider_id")),
      scope: Map.get(candidate, :scope, Map.get(candidate, "scope"))
    }
  end

  defp observe_scoping(_candidate), do: %{provider_id: nil, scope: nil}

  defp persist_snapshot(wakeup, goal, run, snapshot, now, opts) do
    run_id = if run, do: run.id, else: nil

    # Schema v2: `EventPayload.capacity_snapshot/2` carries `freshness` and
    # `reason`, which the strict v1 schema rejects as unsupported fields.
    # The event is recorded at observation time (Observatory precedent): a
    # wake delayed past the freshness window still persists the reading it
    # acted on, and evaluation judges staleness against perform-time `now`.
    attrs = %{
      "type" => "capacity.snapshot_observed",
      "schema_version" => 2,
      "actor" => Keyword.get(opts, :actor, @actor),
      "occurred_at" => snapshot.observed_at || now,
      "idempotency_key" => "wakeup-snapshot:#{wakeup.id}:#{snapshot.snapshot_id}",
      "payload" => EventPayload.capacity_snapshot(snapshot, run_id)
    }

    trusted = if run_id, do: [run_id: run_id], else: []

    case Trajectory.append(goal.id, attrs,
           trusted: trusted,
           writer_opts: Keyword.get(opts, :writer_opts, [])
         ) do
      {:ok, event} -> {:ok, event}
      {:error, reason} -> {:error, {:snapshot_persist_failed, reason}}
    end
  end

  defp evaluate(repo, goal, snapshot, request, candidate, now, opts) do
    policy = Keyword.get(opts, :policy, AdmissionPolicy.default())

    with {:ok, occupancy} <- occupancy(repo, goal, opts) do
      case AdmissionEvaluation.evaluate(request, candidate, snapshot, policy,
             now: now,
             occupancy: occupancy
           ) do
        {:ok, evaluation} -> {:ok, evaluation}
        {:error, reason} -> {:error, {:evaluation_failed, reason}}
      end
    end
  end

  defp admission_context(repo, wakeup, goal, run, opts) do
    request = Keyword.get(opts, :request)
    candidate = Keyword.get(opts, :candidate)

    if is_map(request) and is_map(candidate) do
      {:ok, {request, candidate}}
    else
      with {:ok, decision} <- context_decision(repo, wakeup, goal, opts) do
        {:ok, {context_request(goal.id, run, decision), context_candidate(decision)}}
      end
    end
  end

  defp context_decision(repo, _wakeup, goal, opts) do
    case Keyword.get(opts, :decision_event_id) do
      nil ->
        latest_decision(repo, goal.id)

      event_id ->
        case repo.get(TrajectoryEvent, event_id) do
          %TrajectoryEvent{goal_id: goal_id, payload: payload} when goal_id == goal.id ->
            decision_from_payload(payload)

          _other ->
            {:error, {:admission_event_not_found, event_id}}
        end
    end
  end

  defp latest_decision(repo, goal_id) do
    event =
      repo.one(
        from event in TrajectoryEvent,
          where: event.goal_id == ^goal_id and event.type == "admission.decided",
          order_by: [desc: event.sequence],
          limit: 1
      )

    case event do
      %TrajectoryEvent{payload: payload} -> decision_from_payload(payload)
      nil -> {:error, :missing_admission_context}
    end
  end

  defp decision_from_payload(payload) do
    case AdmissionDecision.from_payload(payload) do
      {:ok, decision} -> {:ok, decision}
      {:error, changeset} -> {:error, {:admission_decision_invalid, changeset}}
    end
  end

  defp context_request(goal_id, run, decision) do
    %{
      requested_capability: decision.requested_capability,
      scope: decision.scope,
      goal_id: goal_id,
      task_id: run && run.task_id,
      run_id: run && run.id
    }
  end

  defp context_candidate(decision) do
    %{
      provider_id: decision.candidate.provider_id,
      adapter_id: decision.candidate.adapter_id,
      support_tier: decision.candidate.support_tier,
      compatibility_state: decision.candidate.compatibility_state,
      scope: decision.scope,
      capabilities: [decision.requested_capability]
    }
  end

  defp occupancy(repo, goal, opts) do
    case Keyword.fetch(opts, :occupancy) do
      {:ok, occupancy} when is_boolean(occupancy) ->
        {:ok, occupancy}

      _other ->
        case Commands.active_claim(repo: repo) do
          %{goal_id: holder} -> {:ok, holder != goal.id}
          nil -> {:ok, false}
        end
    end
  end

  # ----------------------------------------------------------------------------
  # Branches
  # ----------------------------------------------------------------------------

  defp branch(repo, wakeup, goal, run, lease, snapshot, evaluation, now, opts) do
    case evaluation.result do
      :admit ->
        admit_branch(repo, wakeup, goal, run, lease, snapshot, evaluation, now, opts)

      :defer_until ->
        defer_branch(repo, wakeup, goal, run, lease, snapshot, evaluation, now, opts)

      :require_confirmation ->
        confirm_branch(repo, wakeup, goal, evaluation, now)

      :reject ->
        reject_branch(repo, wakeup, goal, run, evaluation, now, opts)
    end
  end

  defp admit_branch(repo, wakeup, goal, run, lease, snapshot, evaluation, now, opts) do
    with {:ok, :evaluating} <- GoalLifecycle.transition(:sleeping, :recheck_due),
         {:ok, :queued} <- GoalLifecycle.apply_decision(:evaluating, :admit),
         {:ok, lease_state} <- renew_lease(repo, goal, lease, snapshot, opts),
         {:ok, run_state} <- resume_run(repo, goal, run, wakeup, now, opts),
         {:ok, dispatch_state} <-
           dispatch_continuation(repo, goal, run, wakeup, evaluation, snapshot, opts),
         {:ok, _position} <- Projector.project(goal.id, clock: clock(opts)),
         {:ok, wakeup} <- mark_status(repo, wakeup, "woken", now) do
      {:ok,
       %{
         outcome: :performed,
         branch: :admitted,
         wakeup_id: wakeup.id,
         lifecycle: :queued,
         decision_id: evaluation.decision_id,
         lease: lease_state,
         run: run_state,
         dispatch: dispatch_state
       }}
    end
  end

  # A renewed lease rests at `:renewed` chained to the fresh snapshot: no
  # `lease.continued` event type exists in the registry (and `Leases` exposes
  # no `:continue` action), so re-activation happens on the next grant. A
  # non-renewable lease fails closed — resuming work under a dead lease
  # would break the checkpoint-before-grant ordering.
  defp renew_lease(_repo, _goal, nil, _snapshot, _opts), do: {:ok, :none}

  # Retry convergence: a lease already renewed (e.g. crash between renewal
  # and the woken mark) is recognized instead of re-driven — the machine has
  # no renewed→renewal_due edge, so re-running ensure_due would fail a retry
  # that has nothing left to do. Re-chain to the current fresh snapshot so a
  # retry on newer observations converges forward, then report renewed.
  defp renew_lease(repo, goal, %ExecutionLeaseRecord{status: "renewed"} = lease, snapshot, opts) do
    goal_id = goal.id
    opts = Keyword.put(opts, :repo, repo)

    with {:ok, _record} <- Leases.chain_snapshot(lease.id, snapshot.snapshot_id, opts) do
      {:ok, :renewed}
    else
      {:error, reason} -> {:error, {:lease_rechain_failed, goal_id, reason}}
    end
  end

  defp renew_lease(repo, goal, %ExecutionLeaseRecord{status: status} = lease, snapshot, opts)
       when status in @renewable_lease_statuses do
    goal_id = goal.id

    with {:ok, _} <- ensure_due(repo, goal_id, lease),
         {:ok, %{state: :renewed}} <-
           Leases.transition(goal_id, lease.id, :renew, Keyword.put(opts, :from, :renewal_due)),
         {:ok, _record} <- Leases.chain_snapshot(lease.id, snapshot.snapshot_id, opts) do
      {:ok, :renewed}
    end
  end

  defp renew_lease(_repo, _goal, %ExecutionLeaseRecord{status: status}, _snapshot, _opts),
    do: {:error, {:lease_not_renewable, status}}

  defp ensure_due(_repo, _goal_id, %ExecutionLeaseRecord{status: "renewal_due"}), do: {:ok, :due}

  defp ensure_due(repo, goal_id, %ExecutionLeaseRecord{id: grant_id}) do
    case Leases.transition(goal_id, grant_id, :renewal_due, repo: repo) do
      {:ok, _} -> {:ok, :due}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resume_run(_repo, _goal, nil, _wakeup, _now, _opts), do: {:ok, :none}

  defp resume_run(_repo, goal, %RunRecord{status: "suspended"} = run, wakeup, now, opts) do
    attrs = %{
      "type" => "run.starting",
      "schema_version" => @schema_version,
      "actor" => Keyword.get(opts, :actor, @actor),
      "occurred_at" => now,
      "idempotency_key" => "wakeup-resume:#{wakeup.id}",
      "payload" => %{"run_id" => run.id}
    }

    case Trajectory.append(goal.id, attrs,
           trusted: [run_id: run.id],
           writer_opts: Keyword.get(opts, :writer_opts, [])
         ) do
      {:ok, _event} -> {:ok, :starting}
      {:error, reason} -> {:error, {:run_resume_failed, reason}}
    end
  end

  # A crash between the resume append and the woken mark re-performs into an
  # already-starting run: skip the append instead of breaking projection.
  defp resume_run(_repo, _goal, %RunRecord{status: "starting"}, _wakeup, _now, _opts),
    do: {:ok, :starting}

  defp resume_run(_repo, _goal, %RunRecord{status: status}, _wakeup, _now, _opts),
    do: {:error, {:unexpected_run_state, status}}

  # Admitted → dispatch → Elf chain (loop-closure I4, P2). The wake's resume
  # decision is already on the trajectory (`run.starting` on the suspended
  # run); the continuation work itself travels through the durable dispatch
  # pipeline so `harness_dispatches` stays the effect truth and the Oban
  # `dispatch`-queue job stays a mere delivery attempt:
  #
  #   wakeup row (due) → admit → `Dispatches.enqueue/3` (new continuation
  #   run + dispatch record + dispatch job, `require_cobbler_command: true`)
  #   → `DispatchWorker` claims the dispatch → Elf executes.
  #
  # The `dispatch_id` is the wakeup row id: deterministic across retries, so
  # a crash between enqueue and the `woken` mark re-performs into the
  # dispatch pipeline's own recovery (one dispatch record, one job), never
  # into `Elves.start_run/3` directly. With no run there is nothing to
  # continue and dispatch stays `:gated`.
  defp dispatch_continuation(_repo, _goal, nil, _wakeup, _evaluation, _snapshot, _opts),
    do: {:ok, :gated}

  defp dispatch_continuation(repo, goal, %RunRecord{} = run, wakeup, evaluation, snapshot, opts) do
    new_run_id = Ecto.UUID.generate()

    with {:ok, continuation} <- ensure_continuation(repo, goal, run, wakeup, evaluation, opts),
         {:ok, request} <- continuation_request(run, wakeup, continuation),
         {:ok, identity} <- resolve_identity(run, opts),
         :ok <- authorize_claim(goal, evaluation, opts),
         {:ok, new_run} <- request_run(repo, request, identity, new_run_id, opts),
         {:ok, _grant} <-
           grant_continuation_lease(repo, goal, new_run, evaluation, snapshot, wakeup, opts),
         {:ok, dispatch, job} <- Dispatches.enqueue_for_run(new_run, dispatch_opts(repo, opts)) do
      {:ok,
       %{
         outcome: :dispatched,
         dispatch_id: dispatch.dispatch_id,
         run_id: dispatch.run_id,
         job_id: job && job.id
       }}
    end
  end

  # The dispatched continuation carries the projected recovery context, not a
  # nil placeholder: the checkpoint projected (or just written) for the
  # suspended run. Same-provider resume reconciles against it; a later
  # handoff forwards it instead of the raw transcript.
  defp continuation_request(%RunRecord{} = run, wakeup, continuation) do
    attrs = %{
      version: run.request_version,
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
      requested_capabilities: wake_capabilities(run),
      dispatch_id: wakeup.id,
      extensions: run.extensions || %{}
    }

    case RunRequest.new(attrs) do
      {:ok, request} -> {:ok, request}
      {:error, changeset} -> {:error, {:wakeup_dispatch_invalid, changeset}}
    end
  end

  # Project the continuation for the suspended run, writing a deterministic
  # fallback checkpoint first when the run (and goal) has none. Fail-closed:
  # a wake that cannot establish recovery context does not dispatch.
  defp ensure_continuation(repo, goal, run, wakeup, evaluation, opts) do
    case Continuation.for_goal(goal.id, repo: repo, run_id: run.id) do
      {:ok, continuation} ->
        {:ok, continuation}

      {:error, :no_checkpoint} ->
        with {:ok, _record} <- write_wake_checkpoint(repo, goal, run, wakeup, evaluation, opts),
             {:ok, _position} <- Projector.project(goal.id, clock: clock(opts)) do
          Continuation.for_goal(goal.id, repo: repo, run_id: run.id)
        end
    end
  end

  defp write_wake_checkpoint(repo, goal, run, wakeup, evaluation, opts) do
    inputs = %{
      checkpoint_id: wakeup.id,
      goal_id: goal.id,
      run_id: run.id,
      acceptance_criteria: Keyword.get(opts, :checkpoint_criteria, [default_criterion()]),
      repository_revision: Keyword.get(opts, :repository_revision, "unknown"),
      evidence: [
        "admitted wake #{wakeup.id} dispatches a continuation for suspended run #{run.id}",
        "admission decision #{evaluation.decision_id} (#{evaluation.reason_code}) on a fresh snapshot"
      ],
      decisions: [],
      unresolved_issues: [],
      stop_reason: "wake_continuation:#{wakeup.id}",
      provider_session_id: run.provider_session_id,
      extensions: %{}
    }

    with {:ok, now} <- resolve_now(opts),
         {:ok, checkpoint} <- CheckpointFallback.build(inputs) do
      case Checkpoints.record(goal.id, checkpoint,
             repo: repo,
             now: now,
             actor: "wakeup",
             writer_opts: Keyword.get(opts, :writer_opts, [])
           ) do
        {:ok, %{checkpoint: _record}} -> {:ok, :written}
        {:error, reason} -> {:error, {:wakeup_checkpoint_failed, reason}}
      end
    else
      {:error, %Ecto.Changeset{}} = error -> {:error, {:wakeup_checkpoint_failed, error}}
      {:error, reason} -> {:error, {:wakeup_checkpoint_failed, reason}}
    end
  end

  # Dispatch identity comes from the suspended run's provider, never from a
  # blanket default: a production wake for a Codex run must not record a Fake
  # identity. An explicit :identity opt still wins (tests pinning Fake).
  defp resolve_identity(run, opts) do
    case Keyword.fetch(opts, :identity) do
      {:ok, identity} -> {:ok, identity}
      :error -> identity_for_provider(run.provider_id)
    end
  end

  # Runs record the adapter id (`RunRecord.provider_id` carries values like
  # "codex_app_server_stdio"); match both adapter ids and short provider
  # names so ledger history from either convention resolves. Unknown →
  # fail-closed, never a default identity.
  defp identity_for_provider("codex"), do: {:ok, CodexAppServer.identity()}
  defp identity_for_provider("codex_app_server_stdio"), do: {:ok, CodexAppServer.identity()}
  defp identity_for_provider("claude"), do: {:ok, ClaudeHeadless.identity()}
  defp identity_for_provider("claude_headless_stream_json"), do: {:ok, ClaudeHeadless.identity()}
  defp identity_for_provider("fake"), do: {:ok, Fake.identity()}
  defp identity_for_provider("shoestring.harness.fake"), do: {:ok, Fake.identity()}
  defp identity_for_provider(other), do: {:error, {:unknown_provider, other}}

  # The wake path dispatches behind the same exclusive-claim gate as every
  # other entrypoint: a lost claim fails the wake instead of dispatching
  # unleased work.
  defp authorize_claim(goal, _evaluation, opts) do
    case Shoestring.Cobbler.DispatchGate.authorize(goal.id, opts) do
      :ok -> :ok
      {:error, reason} -> {:error, {:wakeup_claim_lost, reason}}
    end
  end

  defp request_run(repo, request, identity, new_run_id, opts) do
    run_opts =
      opts
      |> Keyword.take([:clock, :writer_opts, :identifier])
      |> Keyword.put(:repo, repo)
      |> Keyword.put(:run_id, new_run_id)

    case Shoestring.Harness.Runs.request(request, identity, run_opts) do
      {:ok, run} -> {:ok, run}
      {:error, reason} -> {:error, {:wakeup_run_failed, reason}}
    end
  end

  # The new continuation run gets its own lease from the fresh admit
  # decision, chained to the fresh snapshot: a resumed run never executes
  # on the old run's allowance. Bounds mapping mirrors
  # `Shoestring.Cobbler.LeaseGrant` (string-keyed proposed bounds, ISO8601
  # deadline); the replay guard is run-scoped (see below), not
  # decision-scoped, because each wake perform mints a fresh evaluation.
  # Idempotent across retries: an existing grant for the new run row is
  # reused instead of minting a second grant.
  defp grant_continuation_lease(repo, goal, new_run, evaluation, snapshot, wakeup, opts) do
    with {:ok, lease} <- continuation_lease(new_run, evaluation, snapshot, wakeup),
         {:ok, _grant} <- grant_unless_exists(repo, goal, new_run, lease, opts) do
      {:ok, :granted}
    end
  end

  defp grant_unless_exists(repo, goal, new_run, lease, opts) do
    case repo.get_by(ExecutionLeaseRecord, run_id: new_run.id) do
      %ExecutionLeaseRecord{} ->
        {:ok, :reused}

      nil ->
        case Shoestring.Cobbler.Leases.grant(goal.id, lease, Keyword.put(opts, :repo, repo)) do
          {:ok, _result} -> {:ok, :granted}
          {:error, reason} -> {:error, {:wakeup_grant_failed, reason}}
        end
    end
  end

  defp continuation_lease(new_run, evaluation, snapshot, wakeup) do
    bounds = evaluation.proposed_bounds || %{}

    with {:ok, deadline} <- continuation_deadline(bounds["deadline"]),
         {:ok, reserves} <- continuation_reserves(bounds["reserves"]) do
      ExecutionLease.new(%{
        version: ExecutionLease.version(),
        grant_id: Ecto.UUID.generate(),
        run_id: new_run.id,
        admitted_snapshot_id: snapshot.snapshot_id,
        reserves: reserves,
        response_budget: bounds["response_budget"],
        tool_budget: bounds["tool_budget"],
        deadline: deadline,
        checkpoint_cadence: bounds["checkpoint_cadence"],
        renewal_state: :none,
        extensions: %{
          "cobbler.lease:admission_decision_id" => evaluation.decision_id,
          "cobbler.lease:wakeup_id" => wakeup.id
        }
      })
    else
      {:error, reason} -> {:error, {:wakeup_grant_failed, reason}}
    end
  end

  defp continuation_deadline(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, deadline, _offset} -> {:ok, DateTime.truncate(deadline, :microsecond)}
      _error -> {:error, {:deadline, value}}
    end
  end

  defp continuation_deadline(value), do: {:error, {:deadline, value}}

  defp continuation_reserves(%{"response" => response, "tool" => tool})
       when is_integer(response) and is_integer(tool) do
    {:ok, %{response: response, tool: tool}}
  end

  defp continuation_reserves(value), do: {:error, {:reserves, value}}

  defp dispatch_opts(repo, opts) do
    opts
    |> Keyword.take([:clock, :writer_opts])
    |> Keyword.put(:repo, repo)
  end

  # Twin of `Shoestring.Elves.resume_capabilities/1` (I5 owns that file; the
  # copy stays local so this slice never edits Elf-owned code): stored
  # string items back to capability atoms, dropping anything unrecognized.
  defp wake_capabilities(%RunRecord{requested_capabilities: %{"items" => items}})
       when is_list(items) do
    Enum.flat_map(items, fn
      "resume" -> [:resume]
      "send" -> [:send]
      "cancel" -> [:cancel]
      "interactive" -> [:interactive]
      _other -> []
    end)
  end

  defp wake_capabilities(_run), do: []

  defp defer_branch(repo, wakeup, goal, run, lease, _snapshot, evaluation, now, opts) do
    with {:ok, wake_at} <- defer_wake_at(evaluation),
         {:ok, :sleeping} <-
           GoalLifecycle.transition(:sleeping, {:admission_decision, :defer_until}),
         {:ok, lease_state} <- expire_lease(repo, goal, lease, opts),
         {:ok, checkpoint} <-
           defer_checkpoint(repo, goal, run, wakeup, evaluation, wake_at, now, opts),
         {:ok, resleep} <- resleep(repo, goal, run, evaluation, wake_at, now, opts),
         {:ok, _position} <- Projector.project(goal.id, clock: clock(opts)),
         {:ok, wakeup} <- mark_status(repo, wakeup, "woken", now) do
      {:ok,
       %{
         outcome: :performed,
         branch: :deferred,
         wakeup_id: wakeup.id,
         lifecycle: :sleeping,
         decision_id: evaluation.decision_id,
         lease: lease_state,
         checkpoint: checkpoint,
         run: run && :suspended,
         resleep_wakeup_id: resleep.wakeup.id,
         resleep_wake_at: resleep.wakeup.wake_at
       }}
    end
  end

  defp defer_wake_at(%{result: :defer_until, defer_until: %DateTime{} = wake_at}),
    do: {:ok, DateTime.truncate(wake_at, :microsecond)}

  defp defer_wake_at(_evaluation), do: {:error, :missing_defer_until}

  defp expire_lease(_repo, _goal, nil, _opts), do: {:ok, :none}

  defp expire_lease(_repo, goal, %ExecutionLeaseRecord{status: status} = lease, opts)
       when status in @renewable_lease_statuses do
    goal_id = goal.id

    with {:ok, %{state: :expired}} <- Leases.transition(goal_id, lease.id, :expire, opts),
         {:ok, %{state: :checkpoint_required}} <-
           Leases.transition(
             goal_id,
             lease.id,
             :require_checkpoint,
             Keyword.put(opts, :from, :expired)
           ) do
      {:ok, :checkpoint_required}
    end
  end

  defp expire_lease(_repo, _goal, %ExecutionLeaseRecord{status: status}, _opts),
    do: {:error, {:lease_not_expirable, status}}

  # Checkpoint contents for the deferral. The checkpoint id is the wakeup
  # id: deterministic across retries, so a crash between the checkpoint
  # append and the woken mark replays instead of duplicating.
  defp defer_checkpoint(_repo, _goal, nil, _wakeup, _evaluation, _wake_at, _now, _opts),
    do: {:ok, :skipped_no_run}

  defp defer_checkpoint(repo, goal, run, wakeup, evaluation, wake_at, now, opts) do
    inputs = %{
      checkpoint_id: wakeup.id,
      goal_id: goal.id,
      run_id: run.id,
      acceptance_criteria: Keyword.get(opts, :checkpoint_criteria, [default_criterion()]),
      repository_revision: Keyword.get(opts, :repository_revision, "unknown"),
      stop_reason: "deferred_until:#{DateTime.to_iso8601(wake_at)}",
      extensions: %{}
    }

    with {:ok, checkpoint} <- CheckpointFallback.build(inputs),
         {:ok, recorded} <-
           Checkpoints.record(
             goal.id,
             checkpoint,
             Keyword.merge(opts, repo: repo, now: now, actor: Keyword.get(opts, :actor, @actor))
           ) do
      {:ok,
       %{
         checkpoint_id: recorded.checkpoint_id,
         outcome: recorded.outcome,
         reason: evaluation.reason_code
       }}
    end
  end

  defp default_criterion,
    do: "complete the supervised task per the goal acceptance contract"

  defp resleep(_repo, goal, run, evaluation, wake_at, now, opts) do
    resleep_opts =
      opts
      |> Keyword.put(:decision_id, evaluation.decision_id)
      |> Keyword.put(:defer_until, wake_at)
      |> Keyword.put(:wake_at, wake_at)
      |> Keyword.put(:now, now)
      |> Keyword.put(:run_id, run && run.id)
      |> Keyword.put(:reason, "defer_until")
      |> Keyword.put(:request, context_request(goal.id, run, evaluation))
      |> Keyword.put(:candidate, context_candidate(evaluation))

    case schedule(goal.id, resleep_opts) do
      {:ok, %{wakeup: wakeup, outcome: outcome}} -> {:ok, %{wakeup: wakeup, outcome: outcome}}
      {:error, reason} -> {:error, {:resleep_failed, reason}}
    end
  end

  defp confirm_branch(repo, wakeup, goal, evaluation, now) do
    with {:ok, :sleeping} <-
           GoalLifecycle.transition(:sleeping, {:admission_decision, :require_confirmation}),
         {:ok, wakeup} <- mark_status(repo, wakeup, "woken", now) do
      {:ok,
       %{
         outcome: :performed,
         branch: :require_confirmation,
         wakeup_id: wakeup.id,
         lifecycle: :sleeping,
         decision_id: evaluation.decision_id,
         reason_code: evaluation.reason_code,
         operator_action: :confirmation_required,
         pending_commands: pending_command_ids(repo, goal.id)
       }}
    end
  end

  defp pending_command_ids(repo, goal_id) do
    repo.all(
      from command in Shoestring.Cobbler.CommandRecord,
        where: command.goal_id == ^goal_id and command.status == "needs_user",
        order_by: [asc: command.inserted_at, asc: command.id],
        select: command.command_id
    )
  end

  defp reject_branch(repo, wakeup, goal, run, evaluation, now, opts) do
    with {:ok, :handing_off} <-
           GoalLifecycle.transition(:sleeping, {:admission_decision, :reject}),
         {:ok, cancelled} <- cancel_siblings(repo, wakeup, now),
         {:ok, run_state} <- cancel_run(repo, goal, run, wakeup, now, opts),
         {:ok, _position} <- Projector.project(goal.id, clock: clock(opts)),
         {:ok, wakeup} <- mark_status(repo, wakeup, "woken", now) do
      {:ok,
       %{
         outcome: :performed,
         branch: :rejected,
         wakeup_id: wakeup.id,
         lifecycle: :handing_off,
         decision_id: evaluation.decision_id,
         reason_code: evaluation.reason_code,
         cancelled_wakeups: cancelled,
         run: run_state
       }}
    end
  end

  @doc """
  Cancels all pending (`scheduled`/`due`) wakeups for a goal, except the
  optionally given one. Returns `{:ok, count}`.
  """
  @spec cancel_pending(Ecto.UUID.t(), keyword()) :: {:ok, non_neg_integer()}
  def cancel_pending(goal_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    except = Keyword.get(opts, :except)
    {:ok, now} = resolve_now(opts)

    query =
      from wakeup in WakeupRecord,
        where: wakeup.goal_id == ^goal_id and wakeup.status in ["scheduled", "due"]

    query =
      if except do
        from wakeup in query, where: wakeup.id != ^except
      else
        query
      end

    {count, _} =
      repo.update_all(query, set: [status: "cancelled", updated_at: now])

    {:ok, count}
  end

  defp cancel_siblings(repo, wakeup, now) do
    cancel_pending(wakeup.goal_id, repo: repo, except: wakeup.id, now: now)
  end

  defp cancel_run(_repo, _goal, nil, _wakeup, _now, _opts), do: {:ok, :none}

  defp cancel_run(_repo, goal, %RunRecord{status: "suspended"} = run, wakeup, now, opts) do
    actor = Keyword.get(opts, :actor, @actor)
    writer_opts = Keyword.get(opts, :writer_opts, [])

    with {:ok, _} <-
           append_run_event(
             goal.id,
             run.id,
             "run.cancelling",
             "wakeup-cancel:#{wakeup.id}",
             now,
             actor,
             writer_opts
           ),
         {:ok, _} <-
           append_run_event(
             goal.id,
             run.id,
             "run.cancelled",
             "wakeup-cancelled:#{wakeup.id}",
             now,
             actor,
             writer_opts
           ) do
      {:ok, :cancelled}
    end
  end

  defp cancel_run(_repo, _goal, %RunRecord{status: status}, _wakeup, _now, _opts)
       when status in ["cancelled", "completed", "failed", "interrupted"],
       do: {:ok, status}

  defp cancel_run(_repo, _goal, %RunRecord{status: status}, _wakeup, _now, _opts),
    do: {:error, {:unexpected_run_state, status}}

  defp append_run_event(goal_id, run_id, type, key, now, actor, writer_opts) do
    attrs = %{
      "type" => type,
      "schema_version" => @schema_version,
      "actor" => actor,
      "occurred_at" => now,
      "idempotency_key" => key,
      "payload" => %{"run_id" => run_id}
    }

    case Trajectory.append(goal_id, attrs, trusted: [run_id: run_id], writer_opts: writer_opts) do
      {:ok, event} -> {:ok, event}
      {:error, reason} -> {:error, {:run_cancel_failed, reason}}
    end
  end

  # ----------------------------------------------------------------------------
  # Shared helpers
  # ----------------------------------------------------------------------------

  defp live_goal(repo, goal_id) do
    case repo.get(Goal, goal_id) do
      nil ->
        {:error, :goal_not_found}

      %Goal{status: status} when status in @terminal_goal_statuses ->
        {:error, {:wakeup_rejected, :goal_terminal}}

      %Goal{} = goal ->
        {:ok, goal}
    end
  end

  defp idempotency_key(goal_id, opts) do
    cond do
      command_id = Keyword.get(opts, :command_id) ->
        {:ok, "wakeup:#{goal_id}:#{command_id}"}

      Keyword.get(opts, :decision_id) && Keyword.get(opts, :defer_until) ->
        with {:ok, wake_at} <- cast_datetime(Keyword.get(opts, :defer_until)) do
          {:ok,
           "wakeup:#{goal_id}:#{Keyword.get(opts, :decision_id)}:#{DateTime.to_iso8601(wake_at)}"}
        end

      operator = Keyword.get(opts, :manual_operator) ->
        {:ok, "wakeup:#{goal_id}:manual:#{operator}"}

      true ->
        {:error, :missing_wakeup_identity}
    end
  end

  defp suffixed_key(repo, base) do
    pattern = base <> ":r%"

    count =
      repo.aggregate(
        from(wakeup in WakeupRecord,
          where: wakeup.idempotency_key == ^base or like(wakeup.idempotency_key, ^pattern)
        ),
        :count,
        :id
      )

    "#{base}:r#{count}"
  end

  defp default_reason(opts) do
    cond do
      Keyword.get(opts, :decision_id) -> "defer_until"
      Keyword.get(opts, :manual_operator) -> "manual_recheck"
      Keyword.get(opts, :command_id) -> "command_recheck"
      true -> "scheduled"
    end
  end

  defp wake_at(opts, now) do
    case Keyword.get(opts, :wake_at) do
      nil ->
        case Keyword.get(opts, :defer_until) do
          nil -> {:ok, now}
          defer_until -> cast_datetime(defer_until)
        end

      wake_at ->
        cast_datetime(wake_at)
    end
  end

  defp status_for(wake_at, now) do
    if DateTime.compare(wake_at, now) == :gt do
      {:ok, "scheduled"}
    else
      {:ok, "due"}
    end
  end

  defp cast_datetime(%DateTime{} = datetime), do: {:ok, DateTime.truncate(datetime, :microsecond)}

  defp cast_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :microsecond)}
      _error -> {:error, {:invalid_wake_at, value}}
    end
  end

  defp cast_datetime(value), do: {:error, {:invalid_wake_at, value}}

  defp resolve_now(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = now -> {:ok, DateTime.truncate(now, :microsecond)}
      nil -> {:ok, Clock.now(clock(opts))}
      other -> {:error, {:invalid_now, other}}
    end
  end

  defp clock(opts), do: Keyword.get(opts, :clock, Shoestring.Harness.SystemClock)

  defp cast_goal_id(goal_id) do
    case Ecto.UUID.cast(goal_id) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, {:invalid_goal_id, goal_id}}
    end
  end

  defp mark_status(repo, wakeup, status, now) do
    wakeup
    |> Ecto.Changeset.change(%{status: status, updated_at: now})
    |> repo.update()
  end

  defp unique_conflict?(changeset, field) do
    Enum.any?(changeset.errors, fn
      {^field, {_message, opts}} -> opts[:constraint] == :unique
      _error -> false
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp reconcile_failure(wakeup, reason) do
    %{
      goal_id: wakeup.goal_id,
      wakeup_id: wakeup.id,
      reason: sanitize_reason(reason)
    }
  end

  defp sanitize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp sanitize_reason(reason) when is_tuple(reason) do
    case Tuple.to_list(reason) do
      [tag | _] when is_atom(tag) -> Atom.to_string(tag)
      _ -> "reconciliation_failed"
    end
  end

  defp sanitize_reason(_reason), do: "reconciliation_failed"

  defp emit_reconcile(%{repaired_count: repaired_count, failures: failures}) do
    :telemetry.execute(
      [:shoestring, :cobbler, :wakeup_reconcile],
      %{repaired_count: repaired_count, failure_count: length(failures)},
      %{result: :ok, repaired_count: repaired_count, failures: failures}
    )
  end
end
