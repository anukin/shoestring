defmodule Shoestring.Cobbler.Handoffs do
  @moduledoc """
  Production cross-provider handoff: explicit command in, supervised
  receiver dispatch out (Milestone 05, work package I5-production).

  This is the **only** way to hand a run to another provider.
  `Shoestring.Elves.resume_run/2` used to do it inline — bare receiver row,
  `handoff.created`, `adapter.start/2`, no observation, no admission, no
  lease of its own, outside the dispatch pipeline. That path is gone; it now
  refuses cross-provider with
  `{:error, {:handoff_requires_cobbler_command, detail}}` and keeps only
  same-provider resume.

  ## Three durable steps, never one

      request/3       ->  a `run.handoff` Cobbler command row (intent) plus
                          a `handoff`-queue delivery attempt
      HandoffWorker   ->  the durable consumer of that attempt
      perform/3       ->  observe -> admit -> create -> grant -> dispatch

  The command row is the authority; the Oban job is only a delivery attempt,
  exactly as `cobbler_wakeups` rows relate to `wakeup` jobs. The row commits
  before the job is inserted, so a crash (or an Oban failure) between the two
  leaves a standing intent that `reconcile/1` re-enqueues at the next boot,
  through `Shoestring.Cobbler.HandoffReconciler`. Nothing strands.

  Every effect in `perform/3` is replayed against that row. A handoff that
  crashes mid-flight re-performs into the same `handoff_id`, the same
  receiver run id and the same dispatch id, so a retry converges instead of
  transferring twice. `handoff_id` IS the command row id — derived from
  durable identity, never from wall-clock time or randomness, matching the
  `Shoestring.Cobbler.Wakeups` idempotency-key rule.

  ## What `perform/3` does, in order

    1. **Boundary.** The command names a checkpoint. That checkpoint must
       still be the run's latest projected checkpoint; a newer one means the
       named boundary is stale and the handoff refuses (`:stale_continuation`)
       rather than transferring from a superseded state.
    2. **One active Elf.** A sender with a live supervised Elf, or a run row
       still `starting`/`running`, refuses. Handoff never interrupts, kills
       or races the sender: explicit cancellation is the operator's separate
       act and the Elf reaps its own process group. No timer, lease expiry or
       staleness signal reaches this module — staleness is evidence, never a
       trigger.
    3. **Fresh admission for the RECEIVER.** A fresh capacity observation is
       taken for the receiver provider and persisted as
       `capacity.snapshot_observed`; `AdmissionEvaluation.evaluate/5` judges
       the receiver candidate and the verdict is persisted as
       `admission.decided`. Support tier and compatibility state come from
       that observation — never from `AdmissionEvaluation`'s candidate
       defaults (`:proactive` / `:compatible`), which are fail-open and would
       silently admit an unmeasured receiver. So the receiver's own measured
       state decides: `:incompatible` or `:unsupported` is a hard stop; a
       degraded, unknown-capacity, stale or future-dated observation asks for
       an attributable `:override` (`confirmed_by` plus target
       provider/scope, validated inside admission), which can lift a
       confirmation-class refusal but never a hard stop. Anything other than
       `:admit` refuses with the decision persisted: the refusal is
       auditable, not silent.
    4. **Receiver run + granted lease.** The receiver run is created with a
       bounded, deterministic, transcript-free prompt composed from the
       checkpoint projection, and gets its OWN `ExecutionLease` grant from
       the fresh admit decision's proposed bounds, chained to the fresh
       snapshot. The receiver never executes on the sender's allowance.
    5. **`handoff.created`.** The canonical pointer event, carrying source
       provider, receiver provider, projection version (`contract_version`),
       checkpoint id, decision refs, the receiver's lease grant id and the
       prior run id. Idempotency key `handoff:<handoff_id>`.
    6. **Durable supervised dispatch.** `Dispatches.enqueue_for_run/2` behind
       `DispatchGate.authorize/2`, exactly like the wake path — the dispatch
       row is effect truth and the Oban `dispatch` job is a delivery attempt
       that `DispatchWorker` turns into a supervised Elf. This module never
       calls `adapter.start/2` and never spawns anything itself.

  ## Privacy

  The receiver is a FRESH session. It receives
  `Continuation.compose_handoff_prompt/2` output — checkpoint pointer,
  `next_action`, decision refs and the bounded checkpoint content sections —
  and never the sender's prompt, transcript or provider session id. The
  sender's `provider_session_id` is not read on this path at all.

  ## Remaining window (stated rather than implied)

  The one-active-Elf guard is a check, not a lock. It runs once before the
  observation and again immediately before the receiver row is created — the
  first irreversible step — so a sender Elf that starts, or a claim that
  moves, *during* the admission round trip is caught. It is still
  check-then-act: nothing here holds a lock on the Elf registry or the claim
  row, so a sender Elf starting in the microseconds between the second check
  and `Runs.request/3` would not be seen by this module.

  What backstops that residual window is not this module. The receiver only
  ever executes through `Dispatches.prepare_for_effect/2`, which claims the
  dispatch row, and `Elves.start_elf/3`, which registers by run id and
  returns `{:ok, :already_running, pid}` rather than starting a second Elf.
  Two Elves for one run are prevented there.

  This module never pauses or cancels the sender. A handoff requested while
  the sender is live is refused, not forced: cancellation is a separate
  explicit operator act, and the Elf owns and reaps its own process group. No
  timer, lease expiry or staleness signal reaches this module.

  ## Honest outcomes

  `perform/3` reports what actually happened: `:dispatched` (effect
  performed), `:converged` (the handoff already existed; nothing new was
  created), or `:refused` with the persisted decision id and reason code.
  Refusals are `{:ok, ...}` because a persisted refusal IS a successful
  production outcome; failures to even reach a decision are `{:error, _}`.
  """

  import Ecto.Query
  require Logger

  alias Oban.Job

  alias Shoestring.Cobbler.{
    AdmissionDecision,
    AdmissionEvaluation,
    AdmissionPolicy,
    Command,
    CommandRecord,
    Commands,
    DispatchGate,
    GoalLifecycle,
    HandoffWorker,
    Leases
  }

  alias Shoestring.Harness.{
    CapacitySnapshot,
    CheckpointRecord,
    Clock,
    Continuation,
    DispatchRecord,
    Dispatches,
    EventPayload,
    ExecutionLease,
    ExecutionLeaseRecord,
    Identity,
    Projector,
    RunRecord,
    RunRequest,
    Runs
  }

  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{Goal, TrajectoryEvent}

  @actor "cobbler"
  @command_type "run.handoff"
  @contract_version 1

  # Sender states that are NOT a valid handoff boundary: work may still be
  # in flight. Everything else (suspended, interrupted, completed, failed,
  # cancelled) has stopped producing.
  @active_run_statuses ["starting", "running"]

  # Oban states that count as a live delivery attempt, mirroring
  # `Shoestring.Cobbler.Wakeups`.
  @live_job_states ["available", "scheduled", "executing", "retryable", "suspended"]

  @type outcome :: :dispatched | :converged | :refused

  @type perform_result :: %{
          required(:outcome) => outcome(),
          required(:handoff_id) => Ecto.UUID.t(),
          optional(:run) => RunRecord.t(),
          optional(:dispatch_id) => Ecto.UUID.t(),
          optional(:job_id) => integer() | nil,
          optional(:decision_id) => String.t(),
          optional(:decision_result) => atom(),
          optional(:reason_code) => String.t(),
          optional(:lease) => :granted | :reused
        }

  # ----------------------------------------------------------------------------
  # Intent
  # ----------------------------------------------------------------------------

  @doc """
  Records the durable `run.handoff` intent for a goal and returns its
  `handoff_id`.

  `attrs` is a command map (`"command_id"` optional, `"payload"` required);
  the type is set here. Payload keys: `run_id`, `checkpoint_id`,
  `to_provider_id`, `to_adapter_id`, `scope`, `reason`, `requested_by`, and
  the optional attributable `confirmation` the operator answers a
  confirmation-class receiver refusal with.

  Nothing executes. Re-submitting the same command id with an identical
  digest replays the recorded intent and appends no events, so the caller
  can retry `request/3` freely; a different digest under the same id is a
  conflict, because a handoff intent is not silently editable.
  """
  @spec request(Ecto.UUID.t(), map(), keyword()) ::
          {:ok,
           %{
             command: CommandRecord.t(),
             handoff_id: Ecto.UUID.t(),
             outcome: atom(),
             job: Job.t() | nil
           }}
          | {:error, term()}
  def request(goal_id, attrs, opts \\ []) when is_map(attrs) do
    attrs = attrs |> stringify_keys() |> Map.put("type", @command_type)

    case Commands.submit(goal_id, attrs, opts) do
      {:ok, %{command: command, outcome: outcome}} ->
        # INTENT FIRST, ALWAYS. The command row is committed by `submit/3`
        # before this line runs, so the enqueue below is a delivery attempt
        # on an authority that already exists durably. A crash, or an Oban
        # failure, between the two leaves the intent standing and
        # `reconcile/1` re-enqueues it — the intent is never stranded, and
        # the job is never the authority.
        {:ok,
         %{
           command: command,
           handoff_id: command.id,
           outcome: outcome,
           job: enqueue_delivery(command, opts)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A rejected command is not an intent and gets no delivery attempt.
  defp enqueue_delivery(
         %CommandRecord{status: "resolved", result: %{"kind" => "handoff_requested"}} = command,
         opts
       ) do
    case command |> delivery_changeset() |> Oban.insert(oban_opts(opts)) do
      {:ok, %Job{} = job} ->
        job

      {:error, _reason} ->
        # Reported as "no live delivery attempt", not as a failed request:
        # the durable intent stands and reconcile/1 owns the repair.
        Logger.warning("handoff delivery enqueue failed; intent stands for reconciliation",
          handoff_id: command.id
        )

        nil
    end
  rescue
    _error -> nil
  end

  defp enqueue_delivery(_command, _opts), do: nil

  defp delivery_changeset(%CommandRecord{} = command) do
    HandoffWorker.new(%{
      "goal_id" => command.goal_id,
      "command_id" => command.command_id,
      "handoff_id" => command.id
    })
  end

  defp oban_opts(opts) do
    case Keyword.get(opts, :repo) do
      nil -> []
      repo -> [repo: repo]
    end
  end

  # ----------------------------------------------------------------------------
  # Startup / retry reconciliation
  # ----------------------------------------------------------------------------

  @doc """
  Re-enqueues a delivery attempt for every durable handoff intent that has
  not settled and has no live job.

  This is the crash-window repair: a process that dies between `request/3`'s
  command commit and its Oban insert leaves a standing intent with no
  delivery attempt, and without this pass nothing would ever execute it.
  Mirrors `Shoestring.Cobbler.Wakeups.reconcile/1` — it adds no handoff
  semantics of its own. It never observes a provider, never admits, never
  dispatches; it only restores delivery. Oban uniqueness on `handoff_id`
  makes the re-enqueue duplicate-safe even if the live-job lookup misses.

  An intent is **settled**, and therefore left alone, when either:

    * `handoff.created` exists for it AND the receiver run has its dispatch
      row (the transfer completed end to end), or
    * a handoff-scoped `admission.decided` recorded a non-admit result (the
      transfer was refused; retrying it automatically would re-observe and
      re-decide behind the operator's back — a refusal is answered by a NEW
      command, explicitly).

  Everything else is unsettled and gets a delivery attempt, including a
  handoff whose pointer committed but whose dispatch row is missing:
  `perform/3` converges that case without re-admitting.

  Returns `{:ok, %{repaired_count:, failures:}}`, mirroring
  `Dispatches.reconcile/1`.
  """
  @spec reconcile(keyword()) ::
          {:ok, %{repaired_count: non_neg_integer(), failures: [map()]}} | {:error, term()}
  def reconcile(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    commands =
      repo.all(
        from command in CommandRecord,
          where: command.type == ^@command_type and command.status == "resolved",
          order_by: [asc: command.inserted_at, asc: command.id]
      )

    result =
      Enum.reduce(commands, %{repaired_count: 0, failures: []}, fn command, acc ->
        case safe_repair(repo, command, opts) do
          {:ok, repaired} ->
            %{acc | repaired_count: acc.repaired_count + repaired}

          {:error, reason} ->
            %{acc | failures: acc.failures ++ [%{handoff_id: command.id, reason: reason}]}
        end
      end)

    {:ok, result}
  end

  defp safe_repair(repo, command, opts) do
    repair(repo, command, opts)
  rescue
    _error -> {:error, :reconciliation_failed}
  catch
    _kind, _reason -> {:error, :reconciliation_failed}
  end

  defp repair(repo, %CommandRecord{result: %{"kind" => "handoff_requested"}} = command, opts) do
    cond do
      settled?(repo, command) -> {:ok, 0}
      live_job?(repo, command.id) -> {:ok, 0}
      true -> requeue(command, opts)
    end
  end

  defp repair(_repo, _command, _opts), do: {:ok, 0}

  defp requeue(command, opts) do
    case command |> delivery_changeset() |> Oban.insert(oban_opts(opts)) do
      {:ok, _job} -> {:ok, 1}
      {:error, reason} -> {:error, reason}
    end
  end

  # An intent is settled when the canonical history says its outcome is
  # final. Three ways that happens, all read from events rather than rows:
  #
  #   * the transfer completed (pointer AND the receiver's dispatch row);
  #   * it was refused on evidence (a handoff-scoped non-admit decision);
  #   * it failed permanently (`handoff.failed`).
  #
  # A pointer WITHOUT its dispatch row is deliberately not settled: that is
  # the crash window `converge/5` repairs, and re-delivering it costs one
  # idempotent call.
  defp settled?(repo, %CommandRecord{} = command) do
    case existing_failure(repo, command.goal_id, command.id) do
      {:ok, _event} ->
        true

      :none ->
        case existing_intent(repo, command.goal_id, command.id) do
          {:ok, event} -> receiver_dispatched?(repo, event)
          :none -> refused?(repo, command)
        end
    end
  end

  defp receiver_dispatched?(repo, %TrajectoryEvent{} = event) do
    case event.payload["run_id"] || event.run_id do
      nil -> false
      run_id -> repo.exists?(from d in DispatchRecord, where: d.run_id == ^run_id)
    end
  end

  # A recorded non-admit decision settles the intent: the transfer was
  # refused on evidence, and only a new explicit command may retry it.
  defp refused?(repo, %CommandRecord{} = command) do
    pattern = decision_key_prefix(command.id) <> "%"

    repo.exists?(
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^command.goal_id and event.type == "admission.decided" and
            like(event.idempotency_key, ^pattern) and
            fragment("(? ->> ?) <> ?", event.payload, "result", "admit")
    )
  end

  defp live_job?(repo, handoff_id) do
    states = @live_job_states

    repo.exists?(
      from job in Job,
        where:
          job.state in ^states and
            fragment("json_extract(?, \'$.handoff_id\') = ?", job.args, ^handoff_id)
    )
  rescue
    _error -> false
  end

  # ----------------------------------------------------------------------------
  # Execution
  # ----------------------------------------------------------------------------

  @doc """
  Performs the handoff recorded by a `run.handoff` command.

  Options:

    * `:observe` - required 1-arity (or 0-arity) function returning
      `{:ok, %CapacitySnapshot{}}` for the receiver provider. There is no
      default: a handoff that cannot observe the receiver's capacity does
      not admit it.
    * `:override` - an attributable operator confirmation map
      (`confirmed_by`, optional `target_provider_id` / `target_scope` /
      `intent` / `confirmed_at`). Validated inside admission; it can lift a
      confirmation-class refusal, never a hard stop.
    * `:goal_state` - the goal's current lifecycle state (default
      `:working`); the `:handoff_requested` transition must be legal from it.
    * `:sender_elf` - explicit sender-Elf liveness for callers that already
      know it; defaults to reading the Elf registry.
    * `:policy`, `:occupancy`, `:now`, `:clock`, `:repo`, `:writer_opts`,
      `:identity` - as in `Shoestring.Cobbler.Wakeups.perform_wakeup/2`.
  """
  @spec perform(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, perform_result()} | {:error, term()}
  def perform(goal_id, command_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    goal_id
    |> do_perform(command_id, opts)
    |> settle_permanent_failure(repo, goal_id, command_id, opts)
  end

  defp do_perform(goal_id, command_id, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    now = now(opts)

    with {:ok, goal} <- fetch_goal(repo, goal_id),
         {:ok, command} <- fetch_handoff_command(repo, goal.id, command_id),
         {:ok, intent} <- handoff_intent(command),
         {:ok, sender} <- fetch_sender_run(repo, goal.id, intent["run_id"]),
         # B3 ORDER IS LOAD-BEARING. Authorization and receiver identity are
         # resolved BEFORE the provider is observed, so a lost claim or an
         # unknown receiver produces no provider observation and no
         # `capacity.snapshot_observed` / `admission.decided` event, let
         # alone a run, lease or dispatch. Observing an unauthorized
         # provider is itself an effect: it reaches a CLI and writes an
         # auditable capacity claim into the goal's history.
         :ok <- authorize(goal, opts),
         {:ok, identity} <- receiver_identity(intent, opts),
         :ok <- ensure_no_active_elf(sender, opts) do
      handoff_id = command.id

      # THE IDEMPOTENCY GUARD PRECEDES THE BOUNDARY CHECK, deliberately.
      #
      # The boundary check (checkpoint identity + authorized decision refs)
      # gates *deciding* a transfer. A transfer whose pointer already
      # committed has been decided; it is converged, not re-authorized. Two
      # things make that ordering necessary rather than merely tidy:
      #
      #   * `perform/3` itself appends an `admission.decided`, so the refs
      #     projected after a successful transfer necessarily differ from the
      #     ones the operator authorized against. Re-checking them on a retry
      #     would report `:decision_superseded` for every completed handoff
      #     and a crash between pointer and dispatch could never converge.
      #   * `converge/5` decides nothing: it re-ensures the receiver's
      #     dispatch delivery, which is idempotent, and re-observes and
      #     re-admits nothing.
      case existing_intent(repo, goal.id, handoff_id) do
        {:ok, event} ->
          converge(repo, goal, event, handoff_id, opts)

        :none ->
          with {:ok, checkpoint, continuation} <-
                 boundary(repo, goal, sender, intent, handoff_id, opts) do
            transfer(
              repo,
              goal,
              sender,
              intent,
              checkpoint,
              continuation,
              identity,
              handoff_id,
              now,
              opts
            )
          end
      end
    end
  end

  # ----------------------------------------------------------------------------
  # Permanent failure: durable, explained, and terminal
  # ----------------------------------------------------------------------------

  # Errors that no retry can clear. They describe a durable disagreement
  # between the authorized intent and the world — a boundary that moved, an
  # authorization that no longer matches, a receiver that cannot be named —
  # and re-running `perform/3` will reach the identical conclusion forever.
  #
  # Left OUT of this list, deliberately, is everything that a later attempt
  # could legitimately resolve: a sender still running, a claim momentarily
  # held elsewhere, an unreachable capacity probe, a failed write. Those stay
  # retriable, and the intent stays unsettled so `reconcile/1` keeps it alive
  # across a restart.
  @permanent_reasons [
    :stale_continuation,
    :decision_superseded,
    :handoff_refs_unauthorized,
    :cross_run_resume,
    :session_mismatch
  ]

  @permanent_tags [
    :unknown_provider,
    :handoff_not_allowed,
    :handoff_receiver_missing,
    :invalid_handoff_request,
    :handoff_command_not_found,
    :handoff_command_type_invalid,
    :handoff_not_requested,
    :handoff_run_not_found
  ]

  @doc """
  True when an error from `perform/3` can never be cleared by retrying.

  `Shoestring.Cobbler.HandoffWorker` uses this to cancel a delivery attempt
  instead of burning retries, and `perform/3` uses it to record the durable
  `handoff.failed` event that stops `reconcile/1` resurrecting the intent.
  """
  @spec permanent_error?(term()) :: boolean()
  def permanent_error?(reason) when reason in @permanent_reasons, do: true
  def permanent_error?({tag, _detail}) when tag in @permanent_tags, do: true
  def permanent_error?(_reason), do: false

  # A permanent failure is recorded on the trajectory, not in a row flag and
  # not only in a log line. Three things follow from that, and all three are
  # required by the contract:
  #
  #   * `reconcile/1` reads the same canonical history every other consumer
  #     reads, so a failed intent is never resurrected — not on the next
  #     pass, not after a restart, not after the Oban job table is cleared;
  #   * the reason is operator-visible and attributable, next to the
  #     `handoff.created` that would have been there had it succeeded;
  #   * there is no row-only hidden truth: the event IS the outcome.
  #
  # The append is idempotent under `handoff-failed:<handoff_id>`, so a
  # concurrent second attempt that reaches the same conclusion converges on
  # one record instead of writing two.
  #
  # A failure to WRITE the failure is itself transient and is deliberately
  # not fatal: the original error is still returned, the intent stays
  # unsettled, and the next attempt tries again. Swallowing the original
  # error here would be worse than a retry.
  defp settle_permanent_failure({:error, reason} = result, repo, goal_id, command_id, opts) do
    if permanent_error?(reason) do
      record_failure(repo, goal_id, command_id, reason, opts)
    end

    result
  end

  defp settle_permanent_failure(result, _repo, _goal_id, _command_id, _opts), do: result

  defp record_failure(repo, goal_id, command_id, reason, opts) do
    with %CommandRecord{} = command <- Commands.get(goal_id, command_id, repo: repo),
         :none <- existing_failure(repo, goal_id, command.id) do
      clock = Keyword.get(opts, :clock, Shoestring.Harness.SystemClock)

      Trajectory.append(
        goal_id,
        %{
          "type" => "handoff.failed",
          "schema_version" => 1,
          "actor" => Keyword.get(opts, :actor, @actor),
          "occurred_at" => Clock.now(clock),
          "idempotency_key" => failure_key(command.id),
          "payload" => failure_payload(command, reason)
        },
        writer_opts: Keyword.get(opts, :writer_opts, [])
      )
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  # `reason` is the machine-readable branch point; `detail` is bounded prose
  # for a human reading the timeline. Neither carries adapter output.
  defp failure_payload(%CommandRecord{} = command, reason) do
    intent = command.result || %{}

    %{
      "handoff_id" => command.id,
      "contract_version" => @contract_version,
      "reason" => failure_reason(reason),
      "detail" => failure_detail(reason),
      "extensions" => %{
        "cobbler.handoff:command_id" => command.command_id,
        "cobbler.handoff:requested_by" => intent["requested_by"]
      }
    }
    |> maybe_put("run_id", intent["run_id"])
    |> maybe_put("checkpoint_id", intent["checkpoint_id"])
  end

  defp failure_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason({tag, _detail}) when is_atom(tag), do: Atom.to_string(tag)
  defp failure_reason(_reason), do: "handoff_failed"

  defp failure_detail(reason) do
    reason
    |> inspect(limit: 5, printable_limit: 200)
    |> String.slice(0, 500)
  end

  defp existing_failure(repo, goal_id, handoff_id) do
    key = failure_key(handoff_id)

    case repo.one(
           from event in TrajectoryEvent,
             where:
               event.goal_id == ^goal_id and event.type == "handoff.failed" and
                 event.idempotency_key == ^key,
             limit: 1
         ) do
      %TrajectoryEvent{} = event -> {:ok, event}
      nil -> :none
    end
  end

  defp failure_key(handoff_id), do: "handoff-failed:" <> handoff_id

  # ----------------------------------------------------------------------------
  # Command + boundary
  # ----------------------------------------------------------------------------

  defp fetch_goal(repo, goal_id) do
    case repo.get(Goal, goal_id) do
      %Goal{} = goal -> {:ok, goal}
      nil -> {:error, :goal_not_found}
    end
  end

  defp fetch_handoff_command(repo, goal_id, command_id) do
    case Commands.get(goal_id, command_id, repo: repo) do
      %CommandRecord{type: @command_type} = command -> {:ok, command}
      %CommandRecord{type: type} -> {:error, {:handoff_command_type_invalid, type}}
      nil -> {:error, {:handoff_command_not_found, command_id}}
    end
  end

  # Only a command the store RESOLVED as a handoff request is executable. A
  # rejected or needs_user row carries no admitted intent, and re-deriving
  # one from the raw payload would execute an intent the store refused.
  defp handoff_intent(
         %CommandRecord{status: "resolved", result: %{"kind" => "handoff_requested"}} = command
       ),
       do: {:ok, command.result}

  defp handoff_intent(%CommandRecord{status: status, result: result}),
    do: {:error, {:handoff_not_requested, %{"status" => status, "kind" => result["kind"]}}}

  defp fetch_sender_run(repo, goal_id, run_id) do
    case repo.one(from run in RunRecord, where: run.id == ^run_id and run.goal_id == ^goal_id) do
      %RunRecord{} = run -> {:ok, run}
      nil -> {:error, {:handoff_run_not_found, run_id}}
    end
  end

  # One active Elf. The sender must have stopped producing before the
  # receiver starts: a live Elf or a `starting`/`running` row refuses. This
  # module never cancels, interrupts or signals the sender — cancellation is
  # a separate explicit operator act, and the Elf owns and reaps its own
  # process group. `Elves.whereis/1` is a registry read.
  defp ensure_no_active_elf(%RunRecord{} = sender, opts) do
    live? =
      case Keyword.fetch(opts, :sender_elf) do
        {:ok, value} -> value
        :error -> alive_pid?(Shoestring.Elves.whereis(sender.id))
      end

    cond do
      live? ->
        {:error, {:sender_elf_active, sender.id}}

      sender.status in @active_run_statuses ->
        {:error, {:sender_run_active, sender.status}}

      true ->
        :ok
    end
  end

  defp alive_pid?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp alive_pid?(_other), do: false

  # The command names a checkpoint; production refuses unless that named
  # boundary is STILL the run's latest projected checkpoint. A newer
  # checkpoint means the operator authorized a transfer from a state the run
  # has since left, so the handoff refuses instead of shipping stale context.
  #
  # B4. The presented side is what the OPERATOR AUTHORIZED, read from the
  # durable command payload; the fresh side is what projection says NOW.
  # Feeding projected refs into both sides (the earlier shape) made
  # `match_decisions/2` compare a list with itself, so `:decision_superseded`
  # was unreachable and an admission decided between request and perform
  # rode along silently.
  #
  # The refusal is deliberately conservative: a changed ref set means the
  # authorization no longer describes the transfer, so it refuses and the
  # operator re-authorizes with a NEW command. Nothing here re-authorizes on
  # the operator's behalf, and nothing records a "divergence accepted".
  # Because the refs are digest-covered, a re-submission under the same
  # command id carrying different refs is a conflict rather than a silent
  # replacement, and a restart reconstructs the authorized set from the same
  # durable payload.
  defp boundary(repo, goal, sender, intent, handoff_id, opts) do
    with {:ok, record} <- Continuation.latest_checkpoint(repo, goal.id, run_id: sender.id),
         refs <- comparable_refs(repo, goal.id, handoff_id),
         {:ok, continuation} <- Continuation.project_latest([record], refs),
         :ok <- named_boundary(record, intent),
         {:ok, authorized} <- authorized_refs(intent),
         :ok <-
           Continuation.validate_resume(
             %{
               checkpoint_id: intent["checkpoint_id"],
               decision_refs: authorized,
               run_id: sender.id,
               provider_session_id: nil
             },
             %{
               checkpoint_id: continuation.checkpoint_id,
               decision_refs: continuation.decision_refs,
               run_id: record.run_id,
               provider_session_id: nil
             },
             %{
               mode: :handoff,
               lease_status: sender_lease_status(repo, sender.id, opts),
               confirmation_pending: Keyword.get(opts, :confirmation_pending, false)
             }
           ) do
      {:ok, record, continuation}
    end
  end

  # THE FRESH SIDE OF THE COMPARISON EXCLUDES THIS HANDOFF'S OWN DECISIONS.
  #
  # `transfer/10` persists its own `admission.decided` (keyed
  # `handoff-decision:<handoff_id>:<snapshot_id>`) BEFORE the receiver row,
  # the lease and the pointer. A crash in that window leaves the decision
  # committed and no pointer, so the retry misses the idempotency guard and
  # arrives back here — where an unfiltered projection would show this
  # handoff its own decision as an external change and refuse
  # `:decision_superseded`. Permanently: every retry would re-read the same
  # committed decision. The handoff could never complete and could never be
  # repaired, only abandoned.
  #
  # Excluding by this handoff's own key prefix removes exactly those
  # decisions and nothing else. A decision from any other source — an
  # operator, a wake, another handoff — keeps a different key, stays in the
  # set, and still refuses. The exclusion cannot hide an external change
  # because it is scoped to one handoff id, and a handoff can only write
  # under its own.
  #
  # The same filtered set feeds `project_latest/2`, so the receiver's
  # continuation is byte-identical across retries. That is what lets
  # `Runs.request/3` recover the row a crashed attempt inserted instead of
  # reporting a dispatch-id conflict against a drifted request.
  defp comparable_refs(repo, goal_id, handoff_id) do
    Continuation.decision_refs(repo, goal_id, exclude_key_prefix: decision_key_prefix(handoff_id))
  end

  defp named_boundary(%CheckpointRecord{id: id}, %{"checkpoint_id" => id}), do: :ok
  defp named_boundary(_record, _intent), do: {:error, :stale_continuation}

  # A pre-`decision_refs` intent has no authorized set to compare. There is
  # none in practice (the field is required by `Command.new/1` and no handoff
  # command predates it), and refusing is the only honest answer: an absent
  # authorization is not a matching one.
  defp authorized_refs(%{"decision_refs" => refs}) when is_list(refs), do: {:ok, refs}
  defp authorized_refs(_intent), do: {:error, :handoff_refs_unauthorized}

  defp sender_lease_status(repo, run_id, opts) do
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

  # ----------------------------------------------------------------------------
  # Idempotency
  # ----------------------------------------------------------------------------

  # Read-only guard, before any effect. A `handoff.created` under this
  # handoff's key means the transfer decision already committed, so a retry
  # converges on it and never re-observes or re-admits: re-admitting a
  # transfer that already happened could refuse work the receiver is already
  # doing.
  defp existing_intent(repo, goal_id, handoff_id) do
    key = intent_key(handoff_id)

    case repo.one(
           from event in TrajectoryEvent,
             where:
               event.goal_id == ^goal_id and event.type == "handoff.created" and
                 event.idempotency_key == ^key,
             order_by: [asc: event.sequence],
             limit: 1
         ) do
      %TrajectoryEvent{} = event -> {:ok, event}
      nil -> :none
    end
  end

  defp intent_key(handoff_id), do: "handoff:" <> handoff_id

  # Paired identities — see the comment above `append_decision/7`.
  defp snapshot_key(handoff_id, snapshot),
    do: "handoff-snapshot:#{handoff_id}:#{snapshot.snapshot_id}"

  defp decision_key(handoff_id, snapshot),
    do: "handoff-decision:#{handoff_id}:#{snapshot.snapshot_id}"

  @doc "Idempotency key prefix for a handoff's persisted admission decisions."
  @spec decision_key_prefix(Ecto.UUID.t()) :: String.t()
  def decision_key_prefix(handoff_id), do: "handoff-decision:#{handoff_id}:"

  # Convergence, not a second transfer. The pointer event names the receiver
  # run; the dispatch pipeline is idempotent, so re-ensuring delivery repairs
  # a crash between the pointer and the dispatch row without duplicating
  # either. A missing receiver row means the crash landed before the row
  # insert; that is reported rather than papered over, because re-creating it
  # here would need a fresh admission this branch deliberately does not run.
  defp converge(repo, goal, event, handoff_id, opts) do
    receiver_id = event.payload["run_id"] || event.run_id

    case repo.get(RunRecord, receiver_id) do
      %RunRecord{} = receiver ->
        with :ok <- authorize(goal, opts),
             {:ok, dispatch, job} <-
               Dispatches.enqueue_for_run(receiver, dispatch_opts(repo, opts)) do
          {:ok,
           %{
             outcome: :converged,
             handoff_id: handoff_id,
             run: receiver,
             dispatch_id: dispatch.dispatch_id,
             job_id: job && job.id
           }}
        end

      nil ->
        {:error, {:handoff_receiver_missing, receiver_id}}
    end
  end

  # ----------------------------------------------------------------------------
  # Transfer
  # ----------------------------------------------------------------------------

  defp transfer(
         repo,
         goal,
         sender,
         intent,
         checkpoint,
         continuation,
         identity,
         handoff_id,
         now,
         opts
       ) do
    with {:ok, :handing_off} <- lifecycle(opts),
         {:ok, snapshot} <- observe(intent, opts),
         {:ok, _event} <- persist_snapshot(goal, sender, snapshot, handoff_id, now, opts),
         {:ok, decision_event, decision} <-
           admit(repo, goal, sender, intent, snapshot, handoff_id, now, opts) do
      case decision.result do
        :admit ->
          dispatch(
            repo,
            goal,
            sender,
            intent,
            checkpoint,
            continuation,
            snapshot,
            decision_event,
            decision,
            identity,
            handoff_id,
            opts
          )

        other ->
          {:ok,
           %{
             outcome: :refused,
             handoff_id: handoff_id,
             decision_id: decision.decision_id,
             decision_result: other,
             reason_code: decision.reason_code
           }}
      end
    end
  end

  defp lifecycle(opts) do
    goal_state = Keyword.get(opts, :goal_state, :working)

    case GoalLifecycle.transition(goal_state, :handoff_requested) do
      {:ok, :handing_off} -> {:ok, :handing_off}
      {:error, reason} -> {:error, {:handoff_not_allowed, reason}}
    end
  end

  # Fresh observation of the RECEIVER's capacity, scoped to the receiver
  # provider and scope. There is no default observer: an unobservable
  # receiver is not admitted.
  defp observe(intent, opts) do
    scoping = %{provider_id: intent["to_provider_id"], scope: intent["scope"]}

    result =
      case Keyword.fetch(opts, :observe) do
        {:ok, fun} when is_function(fun, 1) -> fun.(scoping)
        {:ok, fun} when is_function(fun, 0) -> fun.()
        _missing -> {:error, :missing_observe_fun}
      end

    case result do
      {:ok, %CapacitySnapshot{} = snapshot} -> {:ok, snapshot}
      {:error, reason} -> {:error, {:observation_failed, reason}}
      _other -> {:error, {:observation_failed, :unexpected_observe_result}}
    end
  end

  defp persist_snapshot(goal, sender, snapshot, handoff_id, now, opts) do
    attrs = %{
      "type" => "capacity.snapshot_observed",
      "schema_version" => 2,
      "actor" => Keyword.get(opts, :actor, @actor),
      "occurred_at" => snapshot.observed_at || now,
      "idempotency_key" => snapshot_key(handoff_id, snapshot),
      "payload" => EventPayload.capacity_snapshot(snapshot, sender.id)
    }

    case Trajectory.append(goal.id, attrs,
           trusted: [run_id: sender.id],
           writer_opts: Keyword.get(opts, :writer_opts, [])
         ) do
      {:ok, event} -> {:ok, event}
      {:error, reason} -> {:error, {:snapshot_persist_failed, reason}}
    end
  end

  # Honest fresh admission for the receiver, persisted as `admission.decided`
  # v1 before any effect. Support tier and compatibility state are read off
  # the fresh observation, NOT left to `AdmissionEvaluation`'s candidate
  # defaults (`:proactive` / `:compatible`), which would silently admit an
  # unmeasured provider. The `|| :unknown` fallbacks are belt-and-braces:
  # `CapacitySnapshot` requires both fields, so a snapshot that reached here
  # always declares them — but a nil must never become a fail-open default.
  defp admit(repo, goal, sender, intent, snapshot, handoff_id, now, opts) do
    candidate = %{
      provider_id: intent["to_provider_id"],
      adapter_id: intent["to_adapter_id"],
      support_tier: snapshot.support_tier || :unknown,
      compatibility_state: snapshot.compatibility_state || :unknown,
      scope: intent["scope"],
      capabilities: [requested_capability(opts)]
    }

    request =
      %{
        requested_capability: requested_capability(opts),
        scope: intent["scope"],
        goal_id: goal.id,
        task_id: sender.task_id,
        run_id: sender.id
      }
      |> maybe_put(:override, override(intent, opts))

    policy = Keyword.get(opts, :policy, AdmissionPolicy.default())

    with {:ok, occupancy} <- occupancy(repo, goal, opts),
         {:ok, evaluation} <-
           evaluate(request, candidate, snapshot, policy, now: now, occupancy: occupancy) do
      append_decision(goal, sender, evaluation, snapshot, handoff_id, now, opts)
    end
  end

  defp requested_capability(opts),
    do: Keyword.get(opts, :requested_capability, "supervised_execution")

  # The operator's attributable confirmation for THIS transfer, read off the
  # durable intent. `Shoestring.Cobbler.HandoffWorker` — the only production
  # consumer of a handoff intent — passes no `:override`, so before this the
  # only confirmation channel was an in-process caller option and a receiver
  # whose measured capacity was less than automatically safe could never be
  # handed off in production, whatever the operator decided.
  #
  # Precedence is caller option first, intent second, so an in-process caller
  # (and every existing test) keeps its exact previous behaviour. This lifts
  # nothing on its own: `Shoestring.Cobbler.AdmissionEvaluation` re-validates
  # attribution and target, and a hard stop remains a hard stop.
  defp override(intent, opts) do
    case Keyword.get(opts, :override) do
      nil -> intent["confirmation"]
      override -> override
    end
  end

  defp evaluate(request, candidate, snapshot, policy, eval_opts) do
    case AdmissionEvaluation.evaluate(request, candidate, snapshot, policy, eval_opts) do
      {:ok, evaluation} -> {:ok, evaluation}
      {:error, reason} -> {:error, {:evaluation_failed, reason}}
    end
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

  # N1 COHERENCE. The observation and the decision share the same
  # `(handoff_id, snapshot_id)` identity, so they can never be paired
  # incorrectly. A crash-retry that re-observes the SAME reading (the
  # Observatory serves a cached snapshot inside its freshness window)
  # collapses BOTH appends on their idempotency keys: no duplicate
  # observation, no duplicate decision. A retry that genuinely observes
  # something NEW appends a new observation AND the decision taken on it —
  # two honest events, correctly paired.
  #
  # Keying the decision on the handoff alone (the earlier shape) was
  # incoherent in exactly the way that matters: the fresh observation
  # appended, the decision collapsed onto the first one, and the history then
  # showed a new reading beside a verdict that was never taken on it.
  defp append_decision(goal, sender, evaluation, snapshot, handoff_id, now, opts) do
    payload =
      evaluation
      |> AdmissionDecision.to_payload()
      |> Map.put_new("run_id", sender.id)

    attrs = %{
      "type" => "admission.decided",
      "schema_version" => 1,
      "actor" => Keyword.get(opts, :actor, @actor),
      "occurred_at" => now,
      "idempotency_key" => decision_key(handoff_id, snapshot),
      "payload" => payload
    }

    with {:ok, event} <-
           Trajectory.append(goal.id, attrs,
             trusted: [run_id: sender.id],
             writer_opts: Keyword.get(opts, :writer_opts, [])
           ),
         {:ok, decision} <- AdmissionDecision.from_payload(event.payload) do
      {:ok, event, decision}
    else
      {:error, reason} -> {:error, {:handoff_decision_failed, reason}}
    end
  end

  # ----------------------------------------------------------------------------
  # Receiver creation, lease, pointer, dispatch
  # ----------------------------------------------------------------------------

  # Receiver ids are derived from the handoff, not generated: the receiver's
  # dispatch id IS the handoff id, so `Runs.request/3` recovers the row a
  # crashed earlier attempt inserted instead of creating a second one.
  defp dispatch(
         repo,
         goal,
         sender,
         intent,
         checkpoint,
         continuation,
         snapshot,
         decision_event,
         decision,
         identity,
         handoff_id,
         opts
       ) do
    with {:ok, request} <- receiver_request(sender, intent, continuation, checkpoint, handoff_id),
         # N4 re-validation. The guards above ran before the observation and
         # admission round-trip, which is not instantaneous. Both are re-read
         # here, immediately before the first irreversible step (the receiver
         # row), so a claim lost or a sender Elf started DURING admission is
         # caught. This narrows the window; it does not close it, because
         # nothing here holds a lock on either. See the moduledoc's
         # "Remaining window" note.
         :ok <- authorize(goal, opts),
         {:ok, sender} <- fetch_sender_run(repo, goal.id, sender.id),
         :ok <- ensure_no_active_elf(sender, opts),
         {:ok, receiver} <- create_receiver(repo, request, identity, handoff_id, opts),
         {:ok, grant_id, lease_state} <-
           grant_lease(repo, goal, receiver, snapshot, decision_event, decision, handoff_id, opts),
         {:ok, _pointer} <-
           append_pointer(
             goal,
             sender,
             receiver,
             intent,
             checkpoint,
             continuation,
             grant_id,
             handoff_id,
             opts
           ),
         {:ok, record, job} <- Dispatches.enqueue_for_run(receiver, dispatch_opts(repo, opts)),
         {:ok, _position} <- Projector.project(goal.id, clock: projector_clock(opts)) do
      {:ok,
       %{
         outcome: :dispatched,
         handoff_id: handoff_id,
         run: receiver,
         dispatch_id: record.dispatch_id,
         job_id: job && job.id,
         decision_id: decision.decision_id,
         decision_result: :admit,
         reason_code: decision.reason_code,
         lease: lease_state
       }}
    end
  end

  # The receiver's whole context: a bounded, deterministic projection of the
  # checkpoint. The sender's prompt, transcript and provider session id are
  # not read here and cannot reach the receiver.
  defp receiver_request(sender, intent, continuation, checkpoint, handoff_id) do
    attrs = %{
      version: 1,
      goal_id: sender.goal_id,
      task_id: sender.task_id,
      workspace_ref: sender.workspace_ref,
      prompt: Continuation.compose_handoff_prompt(continuation, checkpoint_record: checkpoint),
      continuation: %{
        checkpoint_id: continuation.checkpoint_id,
        next_action: continuation.next_action,
        decision_refs: continuation.decision_refs
      },
      policy: sender.policy || %{mode: "supervised"},
      requested_capabilities: receiver_capabilities(sender),
      dispatch_id: handoff_id,
      extensions: handoff_extensions(sender, intent, handoff_id)
    }

    case RunRequest.new(attrs) do
      {:ok, request} -> {:ok, request}
      {:error, changeset} -> {:error, {:invalid_handoff_request, changeset}}
    end
  end

  # Deliberately does NOT carry `wakeup:resume_prior_session_id`: that key is
  # what makes the Elf prefer `adapter.resume`, and a cross-provider receiver
  # must start fresh. Only handoff provenance is added.
  defp handoff_extensions(sender, intent, handoff_id) do
    (sender.extensions || %{})
    |> Map.delete("wakeup:resume_prior_session_id")
    |> Map.merge(%{
      "cobbler.handoff:handoff_id" => handoff_id,
      "cobbler.handoff:from_provider_id" => sender.provider_id,
      "cobbler.handoff:to_provider_id" => intent["to_provider_id"]
    })
  end

  # Twin of `Shoestring.Elves.resume_capabilities/1` and
  # `Shoestring.Cobbler.Wakeups.wake_capabilities/1`: stored string items back
  # to capability atoms, dropping anything unrecognized.
  defp receiver_capabilities(%RunRecord{requested_capabilities: %{"items" => items}})
       when is_list(items) do
    Enum.flat_map(items, fn
      "resume" -> [:resume]
      "send" -> [:send]
      "cancel" -> [:cancel]
      "interactive" -> [:interactive]
      _other -> []
    end)
  end

  defp receiver_capabilities(_run), do: []

  defp receiver_identity(intent, opts) do
    case Keyword.fetch(opts, :identity) do
      {:ok, %Identity{} = identity} ->
        {:ok, identity}

      :error ->
        identity_for_provider(intent["to_adapter_id"], intent["to_provider_id"])
    end
  end

  # Fail-closed on an unknown receiver: never a default identity. Adapter id
  # first (that is what `RunRecord.provider_id` records), provider name
  # second, so either naming convention resolves.
  defp identity_for_provider(adapter_id, provider_id) do
    Enum.find_value(
      [adapter_id, provider_id],
      {:error, {:unknown_provider, provider_id}},
      fn
        id when id in ["codex", "codex_app_server_stdio", "codex_app_server"] ->
          {:ok, Shoestring.Harness.CodexAppServer.identity()}

        id when id in ["claude", "claude_headless_stream_json"] ->
          {:ok, Shoestring.Harness.ClaudeHeadless.identity()}

        id when id in ["fake", "shoestring.harness.fake"] ->
          {:ok, Shoestring.Harness.Fake.identity()}

        _other ->
          nil
      end
    )
  end

  # The same exclusive-claim gate every other dispatch entrypoint passes: a
  # goal that does not hold the live claim cannot dispatch a receiver.
  defp authorize(goal, opts) do
    case DispatchGate.authorize(goal.id, repo: Keyword.get(opts, :repo, Repo)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:handoff_claim_lost, reason}}
    end
  end

  defp create_receiver(repo, request, identity, handoff_id, opts) do
    run_opts =
      opts
      |> Keyword.take([:clock, :writer_opts, :identifier])
      |> Keyword.put(:repo, repo)
      |> Keyword.put(:run_id, handoff_id)

    case Runs.request(request, identity, run_opts) do
      {:ok, run} -> {:ok, run}
      {:error, reason} -> {:error, {:handoff_run_failed, reason}}
    end
  end

  # The receiver gets its OWN grant from the fresh admit decision, chained to
  # the fresh snapshot. Idempotent: a grant already bound to the receiver row
  # is reused rather than duplicated.
  defp grant_lease(repo, goal, receiver, snapshot, decision_event, decision, handoff_id, opts) do
    case repo.get_by(ExecutionLeaseRecord, run_id: receiver.id) do
      %ExecutionLeaseRecord{id: grant_id} ->
        {:ok, grant_id, :reused}

      nil ->
        with {:ok, lease} <-
               build_lease(receiver, snapshot, decision_event, decision, handoff_id),
             {:ok, _result} <- Leases.grant(goal.id, lease, Keyword.put(opts, :repo, repo)) do
          {:ok, lease.grant_id, :granted}
        else
          {:error, reason} -> {:error, {:handoff_grant_failed, reason}}
        end
    end
  end

  defp build_lease(receiver, snapshot, decision_event, decision, handoff_id) do
    bounds = decision.proposed_bounds || %{}

    with {:ok, deadline} <- lease_deadline(bounds["deadline"]),
         {:ok, reserves} <- lease_reserves(bounds["reserves"]) do
      ExecutionLease.new(%{
        version: ExecutionLease.version(),
        grant_id: Ecto.UUID.generate(),
        run_id: receiver.id,
        admitted_snapshot_id: snapshot.snapshot_id,
        reserves: reserves,
        response_budget: bounds["response_budget"],
        tool_budget: bounds["tool_budget"],
        deadline: deadline,
        checkpoint_cadence: bounds["checkpoint_cadence"],
        renewal_state: :none,
        extensions: %{
          "cobbler.lease:admission_decision_id" => decision.decision_id,
          "cobbler.lease:admission_event_id" => decision_event.id,
          "cobbler.lease:handoff_id" => handoff_id
        }
      })
    end
  end

  defp lease_deadline(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, deadline, _offset} -> {:ok, DateTime.truncate(deadline, :microsecond)}
      _error -> {:error, {:deadline, value}}
    end
  end

  defp lease_deadline(value), do: {:error, {:deadline, value}}

  defp lease_reserves(%{"response" => response, "tool" => tool})
       when is_integer(response) and is_integer(tool),
       do: {:ok, %{response: response, tool: tool}}

  defp lease_reserves(value), do: {:error, {:reserves, value}}

  # The canonical record of the transfer: source, receiver, projection
  # version, boundary, refs, the receiver's own grant and the prior run. No
  # row-only truth — every field a consumer needs is on the event.
  defp append_pointer(
         goal,
         sender,
         receiver,
         intent,
         checkpoint,
         continuation,
         grant_id,
         handoff_id,
         opts
       ) do
    clock = Keyword.get(opts, :clock, Shoestring.Harness.SystemClock)

    with {:ok, payload} <-
           Continuation.handoff_payload(%{
             handoff_id: handoff_id,
             run_id: receiver.id,
             checkpoint_id: checkpoint.id,
             from_provider_id: sender.provider_id,
             to_provider_id: intent["to_provider_id"],
             contract_version: @contract_version,
             next_action: continuation.next_action,
             decision_refs: continuation.decision_refs,
             reason: intent["reason"],
             extensions: %{
               "cobbler.handoff:requested_by" => intent["requested_by"],
               "cobbler.handoff:command_id" => handoff_id
             },
             prior_run_id: sender.id,
             lease_grant_id: grant_id
           }) do
      Trajectory.append(
        goal.id,
        %{
          "type" => "handoff.created",
          "schema_version" => 1,
          "actor" => Keyword.get(opts, :actor, @actor),
          "occurred_at" => Clock.now(clock),
          "idempotency_key" => intent_key(handoff_id),
          "payload" => payload
        },
        trusted: [task_id: sender.task_id, run_id: receiver.id],
        writer_opts: Keyword.get(opts, :writer_opts, [])
      )
    end
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  # Projection catches the receiver lease and run rows up with the canonical
  # events this handoff just appended, so the next read (including this
  # module's own idempotency fast path) sees them.
  defp projector_clock(opts),
    do: Keyword.get(opts, :clock, Shoestring.Harness.SystemClock)

  defp dispatch_opts(repo, opts) do
    opts
    |> Keyword.take([:clock, :writer_opts])
    |> Keyword.put(:repo, repo)
  end

  defp now(opts) do
    case Keyword.fetch(opts, :now) do
      {:ok, %DateTime{} = now} -> now
      _other -> Clock.now(Keyword.get(opts, :clock, Shoestring.Harness.SystemClock))
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  @doc "The command type this module executes."
  @spec command_type() :: String.t()
  def command_type, do: @command_type

  @doc "Sender run statuses that are not a valid handoff boundary."
  @spec active_run_statuses() :: [String.t()]
  def active_run_statuses, do: @active_run_statuses

  @doc false
  @spec command_module() :: module()
  def command_module, do: Command
end
