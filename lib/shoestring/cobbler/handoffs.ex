defmodule Shoestring.Cobbler.Handoffs do
  @moduledoc """
  Production cross-provider handoff: explicit command in, supervised
  receiver dispatch out (Milestone 05, work package I5-production).

  `Shoestring.Elves.resume_run/2` already *projects* a handoff — it validates
  the boundary, appends `handoff.created`, creates the receiver run and calls
  the target adapter directly. That is the projection path and it stays what
  it is. It is NOT production execution: it observes no capacity, evaluates
  no admission for the receiver provider, grants the receiver no lease, and
  bypasses the durable dispatch pipeline, so the receiver runs unsupervised
  and unbudgeted. This module is the production path.

  ## Two durable steps, never one

      request/3   ->  a `run.handoff` Cobbler command row (durable intent)
      perform/3   ->  observe -> admit -> grant -> create -> dispatch

  The split is the point. `request/3` writes intent and nothing else; every
  effect in `perform/3` is replayed against that row. A handoff that crashes
  anywhere after `request/3` re-performs into the same `handoff_id`, the same
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

  ## Honest outcomes

  `perform/3` reports what actually happened: `:dispatched` (effect
  performed), `:converged` (the handoff already existed; nothing new was
  created), or `:refused` with the persisted decision id and reason code.
  Refusals are `{:ok, ...}` because a persisted refusal IS a successful
  production outcome; failures to even reach a decision are `{:error, _}`.
  """

  import Ecto.Query

  alias Shoestring.Cobbler.{
    AdmissionDecision,
    AdmissionEvaluation,
    AdmissionPolicy,
    Command,
    CommandRecord,
    Commands,
    DispatchGate,
    GoalLifecycle,
    Leases
  }

  alias Shoestring.Harness.{
    CapacitySnapshot,
    CheckpointRecord,
    Clock,
    Continuation,
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
  `to_provider_id`, `to_adapter_id`, `scope`, `reason`, `requested_by`.

  Nothing executes. Re-submitting the same command id with an identical
  digest replays the recorded intent and appends no events, so the caller
  can retry `request/3` freely; a different digest under the same id is a
  conflict, because a handoff intent is not silently editable.
  """
  @spec request(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, %{command: CommandRecord.t(), handoff_id: Ecto.UUID.t(), outcome: atom()}}
          | {:error, term()}
  def request(goal_id, attrs, opts \\ []) when is_map(attrs) do
    attrs = attrs |> stringify_keys() |> Map.put("type", @command_type)

    case Commands.submit(goal_id, attrs, opts) do
      {:ok, %{command: command, outcome: outcome}} ->
        {:ok, %{command: command, handoff_id: command.id, outcome: outcome}}

      {:error, reason} ->
        {:error, reason}
    end
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
    * `:policy`, `:occupancy`, `:now`, `:clock`, `:repo`, `:writer_opts`,
      `:identity` - as in `Shoestring.Cobbler.Wakeups.perform_wakeup/2`.
  """
  @spec perform(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, perform_result()} | {:error, term()}
  def perform(goal_id, command_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    now = now(opts)

    with {:ok, goal} <- fetch_goal(repo, goal_id),
         {:ok, command} <- fetch_handoff_command(repo, goal.id, command_id),
         {:ok, intent} <- handoff_intent(command),
         {:ok, sender} <- fetch_sender_run(repo, goal.id, intent["run_id"]),
         :ok <- ensure_no_active_elf(sender, opts),
         {:ok, checkpoint, continuation} <- boundary(repo, goal, sender, intent, opts) do
      handoff_id = command.id

      case existing_intent(repo, goal.id, handoff_id) do
        {:ok, event} ->
          converge(repo, goal, event, handoff_id, opts)

        :none ->
          transfer(repo, goal, sender, intent, checkpoint, continuation, handoff_id, now, opts)
      end
    end
  end

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
  # `decision_refs` are re-projected here rather than carried in the command:
  # a ref list frozen at request time would itself go stale. They are
  # persisted into `handoff.created` below, so the refs the receiver was
  # handed stay auditable. This means the `match_decisions/2` arm of
  # `validate_resume/3` is trivially satisfied on this path — the load-bearing
  # checks here are checkpoint identity, run binding, confirmation and the
  # lease allowlist.
  defp boundary(repo, goal, sender, intent, opts) do
    with {:ok, record} <- Continuation.latest_checkpoint(repo, goal.id, run_id: sender.id),
         refs <- Continuation.decision_refs(repo, goal.id),
         {:ok, continuation} <- Continuation.project_latest([record], refs),
         :ok <- named_boundary(record, intent),
         :ok <-
           Continuation.validate_resume(
             %{
               checkpoint_id: intent["checkpoint_id"],
               decision_refs: refs,
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

  defp named_boundary(%CheckpointRecord{id: id}, %{"checkpoint_id" => id}), do: :ok
  defp named_boundary(_record, _intent), do: {:error, :stale_continuation}

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

  defp transfer(repo, goal, sender, intent, checkpoint, continuation, handoff_id, now, opts) do
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
      "idempotency_key" => "handoff-snapshot:#{handoff_id}:#{snapshot.snapshot_id}",
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
      |> maybe_put(:override, Keyword.get(opts, :override))

    policy = Keyword.get(opts, :policy, AdmissionPolicy.default())

    with {:ok, occupancy} <- occupancy(repo, goal, opts),
         {:ok, evaluation} <-
           evaluate(request, candidate, snapshot, policy, now: now, occupancy: occupancy) do
      append_decision(goal, sender, evaluation, handoff_id, now, opts)
    end
  end

  defp requested_capability(opts),
    do: Keyword.get(opts, :requested_capability, "supervised_execution")

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

  # Keyed by the handoff, so a retry that re-reaches this point (the pointer
  # event has not committed yet) collapses onto the decision it already
  # recorded instead of fanning out decisions — and, downstream, runs.
  defp append_decision(goal, sender, evaluation, handoff_id, now, opts) do
    payload =
      evaluation
      |> AdmissionDecision.to_payload()
      |> Map.put_new("run_id", sender.id)

    attrs = %{
      "type" => "admission.decided",
      "schema_version" => 1,
      "actor" => Keyword.get(opts, :actor, @actor),
      "occurred_at" => now,
      "idempotency_key" => "handoff-decision:#{handoff_id}",
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
         handoff_id,
         opts
       ) do
    with {:ok, request} <- receiver_request(sender, intent, continuation, checkpoint, handoff_id),
         {:ok, identity} <- receiver_identity(intent, opts),
         :ok <- authorize(goal, opts),
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
