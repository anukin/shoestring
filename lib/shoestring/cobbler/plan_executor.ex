defmodule Shoestring.Cobbler.PlanExecutor do
  @moduledoc """
  Durable sequential execution for human-approved immutable plans.

  An approved plan stays inert until an explicit `request_execution/3`.
  From there this module dispatches one plan task at a time through the
  existing admission, command/claim, lease, and durable-dispatch machinery
  (`Shoestring.Cobbler.Dispatcher.claim_and_gate/3` with `grant_lease:`),
  records deterministic gate evidence through
  `Shoestring.Cobbler.PlanGateRunner`, and derives all task, attempt,
  acceptance, and progress state purely from trajectory events.

  ## Properties

  - **Atomic dispatch binding.** Every dispatch re-reads the live plan
    authority at the dispatch boundary and binds the revision number AND
    the content digest. A proposed, rejected, invalid, cyclic, or
    superseded revision cannot dispatch; a digest that moved is stale and
    is refused. Duplicate delivery or concurrent kickoff converges on one
    dispatch (deterministic command/run/dispatch ids plus idempotent
    executor events), never two.
  - **One active plan task per goal.** Even dependency-independent nodes
    run sequentially: while a dispatched task has no acceptance or
    terminal gate outcome, the goal awaits it.
  - **Deterministic order.** The next task is the first unaccepted
    dependency-ready task in `PlanGraph` declared order — a pure function
    of the plan content.
  - **No premature goal completion.** A single run completing never
    completes a multi-task planned goal. The goal completes only after
    every required task is accepted AND the global acceptance gates pass
    at the integrated repository revision. Unplanned goals are untouched:
    without an approved authority and an execution request this module
    returns `:no_authority` / `planned?: false` and writes nothing.
  - **Restart and quota preservation.** Accepted tasks and counters survive
    restart without a planning call. A quota-refused run remains unresolved,
    preserving its task/run/attempt for the existing wake lifecycle. Plan-level
    wake/handoff completion remains pending; this module does not yet bind a
    continuation run back to the active plan attempt.
  - **Bounded amendments.** One new approved execution revision may replace an
    inactive execution. Accepted task contracts/evidence and lifetime counters
    carry forward; unresolved work cannot be replaced. Approval and activation
    recheck late acceptance under the store write transaction.
  - **Safe supersession.** A newer approval stops further dispatch from
    the old revision. Work already dispatched is never cancelled because
    authority changed: its attempt result is still recorded at the safe
    boundary, but it grants no authority to changed work and no
    replacement plan is silently adopted.
  - **One admission per task dispatch.** Lease replay is keyed by
    admission decision, so reusing one admission decision across tasks
    would converge tasks onto one grant. Each task dispatch therefore
    consumes its own admit decision; reusing a decision already bound to
    a grant is refused as `{:admission_reused, detail}`.
  """

  import Bitwise
  import Ecto.Query

  alias Shoestring.Cobbler.{Dispatcher, PlanContract, PlanGateRunner, Plans}
  alias Shoestring.Cobbler.{AdmissionDecision, Commands, PlanRevisionRecord}
  alias Shoestring.Harness.{ExecutionLeaseRecord, RunRecord}
  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{Goal, Task, TrajectoryEvent}

  @actor "cobbler"
  @schema_version 1

  @event_types [
    "cobbler.plan.execution.requested",
    "cobbler.plan.task.dispatched",
    "cobbler.plan.task.accepted",
    "cobbler.plan.task.gate_failed",
    "cobbler.plan.execution.completed"
  ]

  @doc "The trajectory event types this executor reads and writes."
  @spec event_types() :: [String.t()]
  def event_types, do: @event_types

  # ----------------------------------------------------------------------------
  # Explicit execution request
  # ----------------------------------------------------------------------------

  @doc """
  Records the explicit execution request for an approved plan revision.

  `attrs` carries `revision_number`, `digest`, and `admission_event_id`
  (the admit decision the first task dispatch consumes). Planning stays
  inert until this call: without it `advance/2` reports
  `:no_execution_requested` and dispatches nothing.

  Idempotent: the same revision and digest replay the original request;
  a different digest under the same execution id is a conflict.
  """
  @spec request_execution(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, %{execution: map(), outcome: :recorded | :replayed}} | {:error, term()}
  def request_execution(goal_id, attrs, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, goal_id} <- cast_goal_id(goal_id),
         {:ok, revision_number} <- positive_int(attrs, :revision_number),
         {:ok, digest} <- sha_digest(attrs),
         :ok <- ensure_goal(repo, goal_id),
         {:ok, authority} <- live_authority(repo, goal_id),
         :ok <- bind_authority(authority, revision_number, digest),
         {:ok, contract} <- PlanContract.new(authority.revision.content),
         :ok <- check_contract_digest(authority, contract),
         {:ok, profile} <-
           Shoestring.Cobbler.ExecutionProfile.resolve(
             Map.get(attrs, :agent_profile, Map.get(attrs, "agent_profile")),
             repo
           ),
         :ok <- request_admission(repo, goal_id, attrs, profile, opts) do
      execution_id = execution_id(attrs, revision_number, digest)

      payload =
        %{
          "execution_id" => execution_id,
          "revision_number" => revision_number,
          "plan_digest" => digest,
          "ordered_task_ids" => contract.ordered_task_ids
        }
        |> maybe_put("agent_profile", profile)
        |> maybe_put("repository_path", Map.get(attrs, :repository_path))
        |> maybe_put("requested_by", Map.get(attrs, :requested_by))

      Plans.record_execution_request(
        goal_id,
        payload,
        "plan-execution:#{revision_number}:#{digest}",
        opts
      )
      |> case do
        {:ok, %{outcome: outcome}} ->
          {:ok,
           %{
             execution:
               %{
                 execution_id: execution_id,
                 revision_number: revision_number,
                 plan_digest: digest,
                 ordered_task_ids: contract.ordered_task_ids
               }
               |> maybe_put(:agent_profile, profile),
             outcome: outcome
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ----------------------------------------------------------------------------
  # Atomic dispatch boundary
  # ----------------------------------------------------------------------------

  @doc """
  Dispatches at most one ready plan task through the durable pipeline.

  Re-reads the live authority, refuses superseded or stale bindings,
  releases this goal's prior plan claim, consumes one admit decision, and
  persists the run row plus lease grant before enqueueing durable
  delivery — via `Dispatcher.claim_and_gate/3`, never a direct spawn.

  Returns `{:ok, %{disposition: ...}}` with `:dispatched`, `:awaiting_task`,
  `:blocked`, or `:completed`, or `{:error, reason}`. Duplicate or
  concurrent calls converge: at most one dispatch per task attempt.
  """
  @spec advance(Ecto.UUID.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def advance(goal_id, opts \\ []) do
    # At-most-once dispatch under concurrency rests on deterministic
    # command/run/dispatch ids plus idempotent executor events — NOT on a
    # mutex (`:global.trans` does not mutual-exclude on `nonode@nohost`,
    # verified empirically). Concurrent kickoffs converge on the winner's
    # run: the stores replay identical intents, a reused admission is
    # refused before any side effect, and a loser converges on the
    # winner's recorded event (or retries into it). Gate execution in
    # `complete_task_run/3` likewise appends idempotently.
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, goal_id} <- cast_goal_id(goal_id),
         :ok <- ensure_goal(repo, goal_id),
         {:ok, projection} <- project(repo, goal_id),
         {:ok, execution} <- require_execution(projection),
         {:ok, authority} <- live_authority(repo, goal_id),
         :ok <- bind_authority(authority, execution.revision_number, execution.plan_digest),
         {:ok, contract} <- PlanContract.new(authority.revision.content),
         :ok <- check_contract_digest(authority, contract) do
      case completed_event(projection) do
        %{} = completed ->
          {:ok, %{disposition: :completed, execution: execution, completed: completed}}

        nil ->
          advance_from_projection(repo, goal_id, projection, execution, authority, contract, opts)
      end
    end
  end

  @doc """
  Idempotent advance after restart; preserves unresolved quota/stop state.

  When the active task's run already reached a terminal event but its
  gates were never recorded, the terminal is completed first (same
  idempotent record path as `complete_task_run/3`); otherwise this is
  `advance/2`. Quota continuation retains the task id, approved
  revision, attempt lineage, acceptance contract, and checkpoint
  evidence: counters only grow, accepted tasks never re-execute, and
  duplicate wakes converge with at most one continuation.
  """
  @spec resume(Ecto.UUID.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def resume(goal_id, opts \\ []) do
    with {:ok, goal_id} <- cast_goal_id(goal_id) do
      # Gate completion runs outside the dispatch lock (it can take as
      # long as the timeout allows); the follow-up advance re-locks.
      {:ok, projection} = project(Keyword.get(opts, :repo, Repo), goal_id)

      case maybe_complete_active(goal_id, projection, opts) do
        {:error, _reason} = error ->
          error

        _completed_or_nil ->
          advance(goal_id, opts)
      end
    end
  end

  defp maybe_complete_active(goal_id, projection, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, execution} <- require_execution(projection),
         %{} = active <- active_dispatch(projection, execution),
         true <- run_resolvable?(repo, goal_id, active.run_id),
         false <- dispatch_resolved?(projection, active) do
      complete_task_run(goal_id, active.run_id, opts)
    else
      _other -> {:ok, :no_terminal_active}
    end
  end

  # ----------------------------------------------------------------------------
  # Task run completion and gate acceptance
  # ----------------------------------------------------------------------------

  @doc """
  Records the gate outcome for a terminal plan-task run, then returns the
  record without auto-dispatching the next task (drive with `advance/2`
  or `resume/2`). Interrupted/cancelled/quota-refused runs remain unresolved;
  only a successful terminal can reach acceptance gates.

  Every cited task gate executes through `PlanGateRunner` at the actual
  worktree and commit; evidence binds goal, task, revision, digest, run,
  and attempt. A successful run alone never unlocks dependents: all gates
  must verify. Gate failure leaves dependents blocked and records a
  bounded `retry` / `escalate` / `needs_user` state. Oversized output
  fails the attempt; it is never silently truncated.
  """
  @spec complete_task_run(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def complete_task_run(goal_id, run_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, goal_id} <- cast_goal_id(goal_id),
         {:ok, run_id} <- cast_uuid(run_id, :run_id),
         :ok <- ensure_goal(repo, goal_id),
         {:ok, projection} <- project(repo, goal_id),
         {:ok, execution} <- require_execution(projection),
         {:ok, resolved} <- require_active_dispatch(projection, execution, run_id) do
      case resolved do
        {:replayed, plan_task_id, attempt} ->
          {:ok,
           %{
             disposition: :replayed,
             plan_task_id: plan_task_id,
             attempt: attempt,
             run_id: run_id
           }}

        %{} = dispatched ->
          complete_fresh_dispatch(repo, goal_id, projection, execution, dispatched, run_id, opts)
      end
    end
  end

  defp complete_fresh_dispatch(repo, goal_id, projection, execution, dispatched, run_id, opts) do
    with {:ok, terminal} <- require_run_terminal(repo, goal_id, run_id),
         {:ok, {_liveness, contract}} <- contract_for(repo, goal_id, execution),
         {:ok, task_contract} <- plan_task(contract, dispatched.plan_task_id) do
      context = %{
        goal_id: goal_id,
        plan_task_id: dispatched.plan_task_id,
        revision_number: execution.revision_number,
        plan_digest: execution.plan_digest,
        run_id: run_id,
        attempt: dispatched.attempt
      }

      outcome =
        if terminal.type == "run.completed" do
          with {:ok, gate_opts} <- Shoestring.Cobbler.PlanWorkspace.gate_opts(repo, context, opts) do
            run_all_gates(task_contract, context, Keyword.put(opts, :gate_runner_opts, gate_opts))
          end
        else
          {:error,
           {:gate_failed,
            %{
              gate: gate_name(hd(task_contract["gates"])),
              reason: "run.failed",
              duration_ms: 0
            }}}
        end

      case outcome do
        {:ok, gate_evidences} ->
          record_acceptance(repo, goal_id, execution, dispatched, gate_evidences, opts)

        {:error, {:gate_failed, detail}} ->
          record_gate_failure(
            repo,
            goal_id,
            projection,
            execution,
            dispatched,
            contract,
            detail,
            opts
          )

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ----------------------------------------------------------------------------
  # Read-only projection
  # ----------------------------------------------------------------------------

  @doc """
  Derives execution state purely from trajectory events.

  Unplanned goals report `planned?: false` and are otherwise untouched,
  preserving ordinary unplanned-goal behavior.
  """
  @spec status(Ecto.UUID.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def status(goal_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, goal_id} <- cast_goal_id(goal_id),
         {:ok, projection} <- project(repo, goal_id) do
      case projection.execution do
        nil ->
          {:ok, %{planned?: false, completed?: false}}

        execution ->
          accepted = accepted_task_ids(projection, execution)
          active = active_dispatch(projection, execution)

          {:ok,
           %{
             planned?: true,
             completed?: not is_nil(completed_event(projection)),
             execution: execution,
             accepted: accepted |> MapSet.to_list() |> Enum.sort(),
             accepted_count: MapSet.size(accepted),
             total_tasks: length(execution.ordered_task_ids),
             active_task: active && active.plan_task_id,
             needs_user?:
               is_nil(active) and
                 Enum.any?(execution.ordered_task_ids, fn id ->
                   not MapSet.member?(accepted, id) and not retryable?(projection, execution, id)
                 end),
             attempts: attempt_counts(projection, execution),
             total_attempts: total_attempts(projection, execution),
             total_gate_duration_ms: total_gate_duration_ms(projection, execution)
           }}
      end
    end
  end

  # ----------------------------------------------------------------------------
  # Projection
  # ----------------------------------------------------------------------------

  defp project(repo, goal_id) do
    events =
      repo.all(
        from event in TrajectoryEvent,
          where: event.goal_id == ^goal_id and event.type in ^@event_types,
          order_by: [asc: event.sequence]
      )

    {:ok, fold_executor_events(events)}
  end

  defp fold_executor_events(events) do
    Enum.reduce(
      events,
      %{execution: nil, dispatched: [], accepted: [], gate_failed: [], completed: nil},
      fn
        %TrajectoryEvent{type: "cobbler.plan.execution.requested", payload: payload}, acc ->
          execution =
            %{
              execution_id: payload["execution_id"],
              revision_number: payload["revision_number"],
              plan_digest: payload["plan_digest"],
              ordered_task_ids: payload["ordered_task_ids"] || []
            }
            |> maybe_put(:agent_profile, payload["agent_profile"])
            |> maybe_put(:repository_path, payload["repository_path"])
            |> maybe_put(:requested_by, payload["requested_by"])

          %{acc | execution: execution, completed: nil}

        %TrajectoryEvent{type: "cobbler.plan.task.dispatched", payload: payload}, acc ->
          %{acc | dispatched: acc.dispatched ++ [normalize_dispatch(payload)]}

        %TrajectoryEvent{type: "cobbler.plan.task.accepted", payload: payload}, acc ->
          %{acc | accepted: acc.accepted ++ [normalize_resolution(payload)]}

        %TrajectoryEvent{type: "cobbler.plan.task.gate_failed", payload: payload}, acc ->
          %{acc | gate_failed: acc.gate_failed ++ [normalize_resolution(payload)]}

        %TrajectoryEvent{type: "cobbler.plan.execution.completed", payload: payload}, acc ->
          if acc.execution && payload["execution_id"] == acc.execution.execution_id,
            do: %{acc | completed: payload},
            else: acc

        _event, acc ->
          acc
      end
    )
  end

  defp normalize_dispatch(payload) do
    %{
      execution_id: payload["execution_id"],
      plan_task_id: payload["plan_task_id"],
      trajectory_task_id: payload["trajectory_task_id"],
      revision_number: payload["revision_number"],
      plan_digest: payload["plan_digest"],
      run_id: payload["run_id"],
      attempt: payload["attempt"],
      command_id: payload["command_id"],
      grant_id: payload["grant_id"]
    }
  end

  defp normalize_resolution(payload) do
    %{
      execution_id: payload["execution_id"],
      plan_task_id: payload["plan_task_id"],
      revision_number: payload["revision_number"],
      plan_digest: payload["plan_digest"],
      run_id: payload["run_id"],
      attempt: payload["attempt"],
      retry_state: payload["retry_state"],
      commit: payload["commit"],
      duration_ms: payload["duration_ms"] || evidence_duration_ms(payload["evidence"])
    }
  end

  defp evidence_duration_ms(%{"gates" => gates}) when is_list(gates) do
    Enum.reduce(gates, 0, fn gate, acc ->
      acc + (Map.get(gate, "duration_ms") || 0)
    end)
  end

  defp evidence_duration_ms(_evidence), do: 0

  defp require_execution(%{execution: nil}), do: {:error, :no_execution_requested}
  defp require_execution(%{execution: execution}), do: {:ok, execution}

  defp completed_event(%{completed: nil}), do: nil
  defp completed_event(%{completed: completed}), do: completed

  defp dispatches_for(projection, execution) do
    Enum.filter(projection.dispatched, &(&1.execution_id == execution.execution_id))
  end

  defp accepted_task_ids(projection, _execution) do
    projection.accepted
    |> Enum.map(& &1.plan_task_id)
    |> MapSet.new()
  end

  defp failures_for(projection, execution, plan_task_id) do
    projection.gate_failed
    |> Enum.filter(
      &(&1.execution_id == execution.execution_id and &1.plan_task_id == plan_task_id)
    )
    |> Enum.sort_by(& &1.attempt)
  end

  defp dispatch_resolved?(projection, %{
         plan_task_id: task_id,
         attempt: attempt,
         execution_id: execution_id
       }) do
    Enum.any?(
      projection.accepted,
      &(&1.execution_id == execution_id and &1.plan_task_id == task_id and &1.attempt == attempt)
    ) or
      Enum.any?(
        projection.gate_failed,
        &(&1.execution_id == execution_id and &1.plan_task_id == task_id and &1.attempt == attempt)
      )
  end

  defp active_dispatch(projection, execution) do
    projection
    |> dispatches_for(execution)
    |> Enum.sort_by(& &1.attempt)
    |> Enum.find(fn dispatch -> not dispatch_resolved?(projection, dispatch) end)
  end

  defp attempt_counts(projection, _execution) do
    projection.dispatched
    |> Enum.group_by(& &1.plan_task_id, & &1.attempt)
    |> Map.new(fn {task_id, attempts} -> {task_id, length(attempts)} end)
  end

  defp total_attempts(projection, _execution), do: length(projection.dispatched)

  # Durations accumulate from bound gate evidence (accepted) and the
  # recorded attempt durations (gate failures). They only grow: nothing
  # here resets a counter on retry, wake, or restart.
  defp total_gate_duration_ms(projection, _execution) do
    accepted_ms =
      projection.accepted
      |> Enum.reduce(0, fn accepted, acc -> acc + (accepted.duration_ms || 0) end)

    failed_ms =
      projection.gate_failed
      |> Enum.reduce(0, fn failed, acc -> acc + (failed.duration_ms || 0) end)

    accepted_ms + failed_ms
  end

  # ----------------------------------------------------------------------------
  # Advance
  # ----------------------------------------------------------------------------

  defp advance_from_projection(repo, goal_id, projection, execution, authority, contract, opts) do
    ordered = contract.ordered_task_ids
    accepted = accepted_task_ids(projection, execution)

    case active_dispatch(projection, execution) do
      %{} = active ->
        {:ok,
         %{
           disposition: :awaiting_task,
           execution: execution,
           active_task: active.plan_task_id,
           active_run_id: active.run_id,
           active_attempt: active.attempt
         }}

      nil ->
        case next_ready_task(contract, ordered, accepted, projection, execution) do
          nil ->
            if MapSet.size(accepted) == length(ordered) do
              complete_execution(repo, goal_id, projection, execution, authority, contract, opts)
            else
              {:ok,
               %{
                 disposition: :blocked,
                 execution: execution,
                 accepted: accepted |> MapSet.to_list() |> Enum.sort()
               }}
            end

          next_task_id ->
            dispatch_task(
              repo,
              goal_id,
              projection,
              execution,
              authority,
              contract,
              next_task_id,
              opts
            )
        end
    end
  end

  defp next_ready_task(contract, ordered, accepted, projection, execution) do
    tasks_by_id = Map.new(contract.content["tasks"], &{&1["id"], &1})

    Enum.find(ordered, fn task_id ->
      task = Map.fetch!(tasks_by_id, task_id)

      not MapSet.member?(accepted, task_id) and
        Enum.all?(task["depends_on"] || [], &MapSet.member?(accepted, &1)) and
        retryable?(projection, execution, task_id)
    end)
  end

  # A task whose latest gate outcome is `escalate` or `needs_user` stays
  # blocked for an operator; only a `retry` outcome (or no failure yet)
  # is dispatchable by the executor itself.
  defp retryable?(projection, execution, task_id) do
    case failures_for(projection, execution, task_id) do
      [] ->
        true

      failures ->
        match?(%{retry_state: "retry"}, List.last(failures))
    end
  end

  defp require_active_dispatch(projection, execution, run_id) do
    case Enum.find(dispatches_for(projection, execution), &(&1.run_id == run_id)) do
      nil ->
        {:error, {:unknown_plan_run, run_id}}

      %{plan_task_id: task_id, attempt: attempt} = dispatch ->
        if dispatch_resolved?(projection, dispatch) do
          {:ok, {:replayed, task_id, attempt}}
        else
          {:ok, dispatch}
        end
    end
  end

  # ----------------------------------------------------------------------------
  # Dispatch
  # ----------------------------------------------------------------------------

  defp dispatch_task(repo, goal_id, projection, execution, _authority, contract, task_id, opts) do
    with {:ok, task_contract} <- plan_task(contract, task_id),
         :ok <- check_budgets(contract, task_contract, projection, execution) do
      attempt = Map.get(attempt_counts(projection, execution), task_id, 0) + 1

      case recover_crashed_dispatch(repo, goal_id, execution, task_contract, attempt, opts) do
        {:recovered, result} ->
          {:ok, result}

        :fresh ->
          fresh_dispatch(
            repo,
            goal_id,
            projection,
            execution,
            contract,
            task_contract,
            attempt,
            opts
          )
      end
    end
  end

  # Crash-window recovery: run ids are deterministic per (goal, task,
  # attempt), so a dispatch that persisted its run row and lease but
  # crashed before recording the dispatched event is recognized here and
  # converged onto the recorded event instead of dispatching a second
  # run for the same attempt.
  defp recover_crashed_dispatch(repo, goal_id, execution, task_contract, attempt, opts) do
    task_id = task_contract["id"]
    run_id = deterministic_uuid("plan-run:#{goal_id}:#{task_id}:#{attempt}")

    case repo.get(RunRecord, run_id) do
      nil ->
        :fresh

      %RunRecord{} = run ->
        grant_id = grant_id_for_run(repo, goal_id, run_id)
        command_id = "plan-#{task_id}-#{attempt}"

        payload =
          %{
            "execution_id" => execution.execution_id,
            "plan_task_id" => task_id,
            "trajectory_task_id" => run.task_id,
            "revision_number" => execution.revision_number,
            "plan_digest" => execution.plan_digest,
            "run_id" => run.id,
            "attempt" => attempt,
            "command_id" => command_id
          }
          |> maybe_put("grant_id", grant_id)

        case append_executor_event(
               repo,
               goal_id,
               "cobbler.plan.task.dispatched",
               payload,
               "plan-task-dispatched:#{task_id}:#{attempt}",
               opts
             ) do
          {:ok, _event} ->
            {:recovered,
             %{
               disposition: :dispatched,
               outcome: :recovered,
               plan_task_id: task_id,
               attempt: attempt,
               run_id: run.id,
               revision_number: execution.revision_number,
               plan_digest: execution.plan_digest
             }}

          {:error, reason} ->
            {:recovered, %{disposition: :recovered_error, reason: reason}}
        end
    end
  end

  defp grant_id_for_run(repo, goal_id, run_id) do
    repo.one(
      from lease in ExecutionLeaseRecord,
        where: lease.goal_id == ^goal_id and lease.run_id == ^run_id,
        select: lease.id,
        limit: 1
    )
  end

  defp fresh_dispatch(
         repo,
         goal_id,
         projection,
         execution,
         contract,
         task_contract,
         attempt,
         opts
       ) do
    task_id = task_contract["id"]

    with {:ok, traj_task} <- ensure_trajectory_task(repo, goal_id, task_id, task_contract),
         {:ok, admission} <-
           task_admission(repo, goal_id, execution, task_contract, attempt, opts),
         :ok <-
           Shoestring.Cobbler.ExecutionProfile.admission(
             execution[:agent_profile],
             admission.payload
           ),
         :ok <- refuse_bound_admission(repo, goal_id, admission),
         {:ok, opts} <-
           prepare_workspace(goal_id, projection, contract, task_id, attempt, opts),
         :ok <- release_own_claim(repo, goal_id, task_id, attempt, opts),
         {:ok, command_attrs} <- claim_attrs(admission, task_id, attempt),
         {:ok, gated} <-
           Dispatcher.claim_and_gate(
             goal_id,
             command_attrs,
             dispatch_opts(
               repo,
               traj_task,
               task_id,
               attempt,
               task_contract,
               contract,
               execution,
               opts
             )
           ),
         {:ok, {:leased, leased}} <- require_leased(gated, repo, goal_id, task_id, attempt),
         :ok <- refuse_replayed_lease(leased, admission),
         {:ok, _event} <-
           append_executor_event(
             repo,
             goal_id,
             "cobbler.plan.task.dispatched",
             %{
               "execution_id" => execution.execution_id,
               "plan_task_id" => task_id,
               "trajectory_task_id" => traj_task.id,
               "revision_number" => execution.revision_number,
               "plan_digest" => execution.plan_digest,
               "run_id" => leased.run.id,
               "attempt" => attempt,
               "command_id" => command_attrs["command_id"]
             }
             |> maybe_put("grant_id", leased.grant_id),
             "plan-task-dispatched:#{task_id}:#{attempt}",
             opts
           ) do
      {:ok,
       %{
         disposition: :dispatched,
         outcome: leased.lease_outcome,
         plan_task_id: task_id,
         attempt: attempt,
         run_id: leased.run.id,
         grant_id: leased.grant_id,
         revision_number: execution.revision_number,
         plan_digest: execution.plan_digest
       }}
    else
      {:error, {:lease_refused, _detail}} = error ->
        error

      {:ok, {:replayed, result}} ->
        {:ok, result}

      {:error, reason} ->
        converge_or_error(repo, goal_id, projection, execution, task_id, attempt, reason)
    end
  end

  # A dispatch that failed after a concurrent winner recorded the same
  # attempt converges on the winner instead of reporting a second outcome.
  defp converge_or_error(repo, goal_id, _projection, _execution, task_id, attempt, reason) do
    case find_dispatch(repo, goal_id, task_id, attempt) do
      %{} = dispatch ->
        {:ok, %{disposition: :dispatched, outcome: :replayed, dispatch: dispatch}}

      nil ->
        {:error, reason}
    end
  end

  defp find_dispatch(repo, goal_id, task_id, attempt) do
    repo.one(
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^goal_id and
            event.type == "cobbler.plan.task.dispatched" and
            fragment("(? ->> ?) = ?", event.payload, "plan_task_id", ^task_id),
        order_by: [desc: event.sequence]
    )
    |> case do
      %TrajectoryEvent{payload: %{"attempt" => ^attempt}} = event ->
        normalize_dispatch(event.payload)

      _other ->
        nil
    end
  end

  defp claim_attrs(admission_event, task_id, attempt) do
    payload = admission_event.payload

    {:ok,
     %{
       "type" => "task.claim",
       "command_id" => "plan-#{task_id}-#{attempt}",
       "payload" => %{
         "intent" => payload["requested_capability"],
         "scope" => payload["scope"],
         "candidate" => %{
           "provider_id" => payload["candidate"]["provider_id"],
           "adapter_id" => payload["candidate"]["adapter_id"]
         },
         "admission_event_id" => admission_event.id
       }
     }}
  end

  defp prepare_workspace(goal_id, projection, contract, task_id, attempt, opts) do
    gate_opts = Keyword.get(opts, :gate_runner_opts, [])

    if is_function(Keyword.get(gate_opts, :runner), 3) do
      {:ok, opts}
    else
      run_id = deterministic_uuid("plan-run:#{goal_id}:#{task_id}:#{attempt}")
      accepted = projection.accepted

      base =
        case List.last(accepted) do
          nil -> get_in(contract.content, ["goal", "repository", "base_revision"])
          last -> last.commit
        end

      with {:ok, worktree} <- execution_worktree(run_id, base, opts),
           true <-
             String.starts_with?(worktree.base_commit, base) ||
               {:error, :plan_worktree_base_mismatch} do
        {:ok, Keyword.put(opts, :workspace_ref, worktree.workspace_ref)}
      end
    end
  end

  defp execution_worktree(run_id, base, opts) do
    case Shoestring.Worktrees.get(run_id) do
      {:ok, worktree} ->
        {:ok, worktree}

      {:error, :not_found} ->
        case Keyword.get(opts, :repository_path) do
          path when is_binary(path) -> Shoestring.Worktrees.create(path, run_id, base)
          _ -> {:error, :plan_repository_required}
        end

      error ->
        error
    end
  end

  defp dispatch_opts(repo, traj_task, task_id, attempt, task_contract, contract, execution, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    clock = Keyword.get(opts, :clock, Shoestring.Harness.SystemClock)
    title = task_contract["title"] || task_id

    lease_opts =
      [
        task_id: traj_task.id,
        run_id: deterministic_uuid("plan-run:#{traj_task.goal_id}:#{task_id}:#{attempt}"),
        dispatch_id:
          deterministic_uuid("plan-dispatch:#{traj_task.goal_id}:#{task_id}:#{attempt}"),
        prompt:
          "Plan task #{task_id} attempt #{attempt}: #{title}\n" <>
            Jason.encode!(%{
              "task" => task_contract,
              "goal" => contract.content["goal"],
              "revision_number" => execution.revision_number,
              "plan_digest" => execution.plan_digest
            }) <> profile_instructions(execution[:agent_profile]),
        extensions:
          %{
            Shoestring.Cobbler.PlanBinding.key() => %{
              "revision_number" => execution.revision_number,
              "plan_digest" => execution.plan_digest,
              "execution_id" => execution.execution_id,
              "plan_task_id" => task_id,
              "attempt" => attempt
            }
          }
          |> maybe_put(Shoestring.Cobbler.ExecutionProfile.key(), execution[:agent_profile]),
        workspace_ref: Keyword.get(opts, :workspace_ref, "cobbler/plan-task"),
        clock: clock,
        now: now,
        repo: repo
      ]
      |> then(fn fixed -> Keyword.merge(Keyword.get(opts, :grant_lease_extra, []), fixed) end)
      |> then(fn fixed ->
        case execution[:agent_profile] do
          nil ->
            fixed

          profile ->
            Keyword.put(fixed, :identity, Shoestring.Cobbler.ExecutionProfile.identity(profile))
        end
      end)

    [grant_lease: lease_opts, repo: repo, now: now, clock: clock]
    |> Keyword.merge(Keyword.take(opts, [:writer_opts]))
  end

  defp profile_instructions(nil), do: ""

  defp profile_instructions(profile),
    do: "\nSaved agent instructions:\n" <> profile["instructions"]

  # One admission decision funds exactly one task dispatch: lease replay
  # is keyed by admission decision, so a decision already bound to a
  # grant would silently share another task's lease. Refuse BEFORE any
  # side effect (no command row, no claim), so the legitimate retry
  # with a fresh admission finds a clean command id.
  defp refuse_bound_admission(repo, goal_id, admission) do
    decision_id = admission.payload["decision_id"]

    event_bound? =
      repo.all(
        from event in TrajectoryEvent,
          where: event.goal_id == ^goal_id and event.type == "lease.proposed",
          select: event.payload
      )
      |> Enum.any?(
        &(get_in(&1, ["extensions", "cobbler.lease:admission_decision_id"]) == decision_id)
      )

    row_bound? =
      repo.all(
        from lease in ExecutionLeaseRecord,
          where: lease.goal_id == ^goal_id,
          select: lease.extensions
      )
      |> Enum.any?(&(&1["cobbler.lease:admission_decision_id"] == decision_id))

    if event_bound? or row_bound? do
      {:error, {:admission_reused, %{admission_event_id: admission.id, decision_id: decision_id}}}
    else
      :ok
    end
  end

  # A dispatch that did not reach `:leased` (a concurrent winner holds
  # the claim under another command, or an operator decision is pending)
  # converges on the winner's recorded event when one exists instead of
  # inventing a second dispatch or crashing on a missing run.
  defp require_leased(%{disposition: :leased} = leased, _repo, _goal_id, _task_id, _attempt) do
    {:ok, {:leased, leased}}
  end

  defp require_leased(_gated, repo, goal_id, task_id, attempt) do
    case find_dispatch(repo, goal_id, task_id, attempt) do
      %{} = dispatch ->
        {:ok, {:replayed, %{disposition: :dispatched, outcome: :replayed, dispatch: dispatch}}}

      nil ->
        {:error, {:plan_claim_unavailable, %{plan_task_id: task_id, attempt: attempt}}}
    end
  end

  # Belt and braces behind the pre-check above: a replay here means the
  # consumed admission was already bound to a grant, so this dispatch
  # would silently share another task's lease. Refuse instead.
  defp refuse_replayed_lease(%{lease_outcome: :replayed}, admission) do
    {:error,
     {:admission_reused,
      %{admission_event_id: admission.id, decision_id: admission.payload["decision_id"]}}}
  end

  defp refuse_replayed_lease(_leased, _admission), do: :ok

  defp release_own_claim(repo, goal_id, task_id, attempt, opts) do
    case Commands.active_claim(repo: repo) do
      %{goal_id: ^goal_id} ->
        Commands.submit(
          goal_id,
          %{
            "type" => "task.release",
            "command_id" => "plan-release-#{task_id}-#{attempt}",
            "payload" => %{"reason" => "plan sequential advance to #{task_id}"}
          },
          Keyword.take(opts, [:repo, :now, :writer_opts])
        )
        |> case do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      %{goal_id: _other} ->
        {:error, {:claim_held_by_other_goal, %{plan_task_id: task_id}}}

      nil ->
        :ok
    end
  end

  # ----------------------------------------------------------------------------
  # Gates
  # ----------------------------------------------------------------------------

  defp run_all_gates(task_contract, context, opts) do
    gates = task_contract["gates"] || []
    gate_opts = Keyword.get(opts, :gate_runner_opts, [])

    Enum.reduce_while(gates, {:ok, []}, fn gate_ref, {:ok, acc} ->
      case PlanGateRunner.run(gate_ref, context, gate_opts) do
        {:ok, evidence} ->
          case PlanGateRunner.verify(gate_ref, evidence, context, gate_opts) do
            {:ok, :accepted} ->
              {:cont, {:ok, acc ++ [evidence]}}

            {:error, reason} ->
              {:halt,
               {:error,
                {:gate_failed, gate_failure_detail(gate_ref, reason, context, evidence, acc)}}}
          end

        {:error, reason} ->
          detail = gate_failure_detail(gate_ref, reason, context, %{}, acc)
          {:halt, {:error, {:gate_failed, detail}}}
      end
    end)
  end

  defp gate_failure_detail(gate_ref, reason, context, evidence, prior_evidences) do
    %{
      gate: gate_name(gate_ref),
      reason: inspect(reason),
      run_id: context.run_id,
      attempt: context.attempt,
      plan_task_id: context.plan_task_id,
      commit: get_commit(evidence),
      duration_ms: get_duration(evidence) + evidences_duration_ms(prior_evidences)
    }
  end

  defp gate_name(%{"gate" => gate}), do: gate
  defp gate_name(_ref), do: "unknown"

  defp stored_gate_evidence(evidence) do
    %{
      "gate" => evidence.gate,
      "argv" => Enum.join(evidence.gate_argv, " "),
      "commit" => evidence.commit,
      "worktree" => evidence.worktree,
      "exit_status" => evidence.exit_status,
      "output" => evidence.output,
      "duration_ms" => evidence.duration_ms
    }
  end

  defp get_commit(%{commit: commit}), do: commit
  defp get_commit(_evidence), do: "unknown"

  defp get_duration(%{duration_ms: duration}) when is_integer(duration), do: duration
  defp get_duration(_evidence), do: 0

  defp evidences_duration_ms(evidences) do
    Enum.reduce(evidences, 0, fn evidence, acc -> acc + get_duration(evidence) end)
  end

  defp record_acceptance(repo, goal_id, execution, dispatched, gate_evidences, opts) do
    first = hd(gate_evidences)
    commit = first.commit

    # Stored evidence stays within the trajectory secret-scan depth bound
    # (see `Contract.safe_term?/1`): argv is kept as one joined command
    # line rather than a nested list, mirroring why plan revision events
    # carry canonical JSON instead of nested objects.
    evidence = %{
      "gates" => Enum.map(gate_evidences, &stored_gate_evidence/1),
      "run_completed" => true
    }

    payload = %{
      "execution_id" => execution.execution_id,
      "plan_task_id" => dispatched.plan_task_id,
      "revision_number" => execution.revision_number,
      "plan_digest" => execution.plan_digest,
      "run_id" => dispatched.run_id,
      "attempt" => dispatched.attempt,
      "gate" => first.gate,
      "gate_argv" => first.gate_argv,
      "commit" => commit,
      "evidence" => evidence
    }

    with {:ok, _event} <-
           append_executor_event(
             repo,
             goal_id,
             "cobbler.plan.task.accepted",
             payload,
             "plan-task-accepted:#{dispatched.plan_task_id}:#{dispatched.attempt}",
             opts
           ) do
      {:ok,
       %{
         disposition: :accepted,
         plan_task_id: dispatched.plan_task_id,
         attempt: dispatched.attempt,
         run_id: dispatched.run_id,
         commit: commit,
         accepted_count:
           MapSet.size(accepted_task_ids(refresh_projection(repo, goal_id), execution))
       }}
    end
  end

  defp record_gate_failure(
         repo,
         goal_id,
         projection,
         execution,
         dispatched,
         contract,
         detail,
         opts
       ) do
    retry_state = retry_state(contract, projection, execution, dispatched)

    payload =
      %{
        "execution_id" => execution.execution_id,
        "plan_task_id" => dispatched.plan_task_id,
        "revision_number" => execution.revision_number,
        "plan_digest" => execution.plan_digest,
        "run_id" => dispatched.run_id,
        "attempt" => dispatched.attempt,
        "gate" => detail.gate,
        "reason" => detail.reason,
        "retry_state" => retry_state,
        "duration_ms" => detail.duration_ms
      }

    with {:ok, _event} <-
           append_executor_event(
             repo,
             goal_id,
             "cobbler.plan.task.gate_failed",
             payload,
             "plan-task-gate-failed:#{dispatched.plan_task_id}:#{dispatched.attempt}",
             opts
           ) do
      {:ok,
       %{
         disposition: :gate_failed,
         plan_task_id: dispatched.plan_task_id,
         attempt: dispatched.attempt,
         run_id: dispatched.run_id,
         retry_state: retry_state,
         reason: detail.reason
       }}
    end
  end

  # Bounded outcome: total budget exhaustion needs an operator, task
  # budget exhaustion escalates, otherwise the executor may retry.
  defp retry_state(contract, projection, execution, dispatched) do
    task = task_contract!(contract, dispatched.plan_task_id)
    task_max = get_in(task, ["execution", "max_attempts"]) || 1
    total_max = get_in(contract.content, ["budget", "max_total_attempts"]) || 1
    attempts = Map.get(attempt_counts(projection, execution), dispatched.plan_task_id, 1)
    total = total_attempts(projection, execution)

    cond do
      total >= total_max -> "needs_user"
      attempts >= task_max -> "escalate"
      true -> "retry"
    end
  end

  # The goal completes only after every required task is accepted AND
  # the global acceptance gates pass at the integrated repository
  # revision. A global gate failure completes nothing: dependents stay
  # recorded but the goal stays incomplete.
  defp complete_execution(repo, goal_id, projection, execution, _authority, contract, opts) do
    accepted = projection.accepted

    with {:ok, gate_opts} <-
           Shoestring.Cobbler.PlanWorkspace.global_gate_opts(repo, accepted, opts),
         {:ok, global_evidences} <-
           run_global_gates(repo, goal_id, contract, execution, gate_opts),
         first = hd(global_evidences),
         {:ok, _event} <-
           append_executor_event(
             repo,
             goal_id,
             "cobbler.plan.execution.completed",
             %{
               "execution_id" => execution.execution_id,
               "revision_number" => execution.revision_number,
               "plan_digest" => execution.plan_digest,
               "commit" => first.commit,
               "global_gate" => first.gate,
               "evidence" => %{
                 "gates" => Enum.map(global_evidences, &stored_gate_evidence/1)
               }
             },
             "plan-execution-completed:#{execution.execution_id}",
             opts
           ),
         :ok <- release_own_claim(repo, goal_id, "complete", 1, opts) do
      {:ok, %{disposition: :completed, execution: execution, commit: first.commit}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_global_gates(repo, goal_id, contract, execution, gate_opts) do
    gates = get_in(contract.content, ["goal", "acceptance", "gates"]) || []

    context = %{
      goal_id: goal_id,
      plan_task_id: "__global__",
      revision_number: execution.revision_number,
      plan_digest: execution.plan_digest,
      run_id: deterministic_uuid("plan-global:#{execution.execution_id}"),
      attempt: 1
    }

    _ = repo

    Enum.reduce_while(gates, {:ok, []}, fn gate_ref, {:ok, acc} ->
      case PlanGateRunner.run(gate_ref, context, gate_opts) do
        {:ok, evidence} ->
          case PlanGateRunner.verify(gate_ref, evidence, context, gate_opts) do
            {:ok, :accepted} ->
              {:cont, {:ok, acc ++ [evidence]}}

            {:error, reason} ->
              {:halt,
               {:error,
                {:global_gate_failed, %{gate: gate_name(gate_ref), reason: inspect(reason)}}}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  # ----------------------------------------------------------------------------
  # Budgets
  # ----------------------------------------------------------------------------

  defp check_budgets(contract, task_contract, projection, execution) do
    task_max = get_in(task_contract, ["execution", "max_attempts"]) || 1
    total_max = get_in(contract.content, ["budget", "max_total_attempts"]) || 1
    task_id = task_contract["id"]
    attempts = Map.get(attempt_counts(projection, execution), task_id, 0)
    total = total_attempts(projection, execution)

    cond do
      attempts >= task_max ->
        {:error, {:task_attempts_exhausted, %{plan_task_id: task_id, max_attempts: task_max}}}

      total >= total_max ->
        {:error, {:total_attempts_exhausted, %{max_total_attempts: total_max}}}

      true ->
        :ok
    end
  end

  # ----------------------------------------------------------------------------
  # Authority, contract, admission
  # ----------------------------------------------------------------------------

  defp live_authority(repo, goal_id) do
    case Plans.authority(goal_id, repo: repo) do
      nil -> {:error, :no_approved_authority}
      authority -> {:ok, authority}
    end
  end

  defp bind_authority(authority, revision_number, digest) do
    if authority.revision_number == revision_number and authority.digest == digest do
      :ok
    else
      {:error,
       {:authority_mismatch,
        %{
          "requested_revision_number" => revision_number,
          "authority_revision_number" => authority.revision_number
        }}}
    end
  end

  defp check_contract_digest(authority, contract) do
    if authority.digest == contract.digest do
      :ok
    else
      {:error, :plan_digest_mismatch}
    end
  end

  # The attempt contract always comes from the execution's own bound
  # revision row — never from whatever authority is live now. When the
  # plan was superseded mid-flight the attempt result is still recorded
  # truthfully against the revision it ran under, but that recording
  # grants no authority to changed work: `advance/2` re-checks liveness
  # and refuses further dispatch from the old revision.
  defp contract_for(repo, goal_id, execution) do
    case Plans.get_revision(goal_id, execution.revision_number, repo: repo) do
      %PlanRevisionRecord{} = revision ->
        with {:ok, contract} <- PlanContract.new(revision.content),
             true <- revision.digest == contract.digest,
             true <- revision.digest == execution.plan_digest do
          liveness =
            case Plans.authority(goal_id, repo: repo) do
              %{revision_number: number, digest: digest}
              when number == execution.revision_number and digest == execution.plan_digest ->
                :live

              _other ->
                :superseded
            end

          {:ok, {liveness, contract}}
        else
          _other -> {:error, {:execution_revision_invalid, execution.revision_number}}
        end

      nil ->
        {:error, {:execution_revision_not_found, execution.revision_number}}
    end
  end

  defp plan_task({_, contract}, task_id), do: plan_task(contract, task_id)

  defp plan_task(contract, task_id) do
    case Enum.find(contract.content["tasks"], &(&1["id"] == task_id)) do
      nil -> {:error, {:unknown_plan_task, task_id}}
      task -> {:ok, task}
    end
  end

  defp task_contract!(contract, task_id) do
    Enum.find(contract.content["tasks"], &(&1["id"] == task_id))
  end

  defp resolve_admission(repo, goal_id, attrs, opts) do
    case admission_event_id(attrs, opts) do
      nil -> latest_admission(repo, goal_id)
      event_id -> fetch_admission(repo, goal_id, event_id)
    end
    |> case do
      {:ok, %TrajectoryEvent{} = event} -> check_admitted(event)
      {:error, reason} -> {:error, reason}
    end
  end

  # A durable CLI request may wait for capacity. Deferral authorizes no run;
  # every task still requires a full admit decision at its dispatch boundary.
  defp request_admission(repo, goal_id, attrs, profile, opts) do
    if Keyword.get(opts, :defer_admission, false) do
      if is_map(profile) and is_binary(attrs[:repository_path]) and
           is_binary(attrs[:requested_by]),
         do: :ok,
         else: {:error, :execution_configuration_required}
    else
      with {:ok, admission} <- resolve_admission(repo, goal_id, attrs, opts),
           do: Shoestring.Cobbler.ExecutionProfile.admission(profile, admission.payload)
    end
  end

  defp task_admission(repo, goal_id, execution, task, attempt, opts) do
    case Keyword.get(opts, :admission_fun) do
      fun when is_function(fun, 4) ->
        with {:ok, event_id} <- fun.(goal_id, execution, task, attempt),
             do: resolve_admission(repo, goal_id, %{admission_event_id: event_id}, [])

      nil ->
        resolve_admission(repo, goal_id, %{}, opts)

      _ ->
        {:error, :invalid_execution_admission}
    end
  end

  defp admission_event_id(attrs, opts) do
    Map.get(attrs, :admission_event_id) || Map.get(attrs, "admission_event_id") ||
      Keyword.get(opts, :admission_event_id)
  end

  defp fetch_admission(repo, goal_id, event_id) do
    case repo.get(TrajectoryEvent, event_id) do
      %TrajectoryEvent{goal_id: ^goal_id} = event -> {:ok, event}
      _other -> {:error, {:admission_not_found, event_id}}
    end
  end

  defp latest_admission(repo, goal_id) do
    repo.all(
      from event in TrajectoryEvent,
        where: event.goal_id == ^goal_id and event.type == "admission.decided",
        order_by: [desc: event.sequence]
    )
    |> List.first()
    |> case do
      nil -> {:error, :no_admit_decision}
      event -> {:ok, event}
    end
  end

  defp check_admitted(%TrajectoryEvent{payload: %{"result" => "admit"}} = event) do
    case AdmissionDecision.from_payload(event.payload) do
      {:ok, %AdmissionDecision{result: :admit}} -> {:ok, event}
      _other -> {:error, {:admission_refused, %{admission_event_id: event.id}}}
    end
  end

  defp check_admitted(%TrajectoryEvent{} = event),
    do: {:error, {:admission_refused, %{admission_event_id: event.id}}}

  # ----------------------------------------------------------------------------
  # Trajectory tasks, runs, commits
  # ----------------------------------------------------------------------------

  defp ensure_trajectory_task(repo, goal_id, plan_task_id, task_contract) do
    uuid = deterministic_uuid("plan-task:#{goal_id}:#{plan_task_id}")
    title = task_contract["title"] || plan_task_id

    changeset =
      %Task{id: uuid}
      |> Task.changeset(%{"title" => title})
      |> Ecto.Changeset.put_change(:goal_id, goal_id)

    case repo.insert(changeset, on_conflict: :nothing) do
      {:ok, _task} -> {:ok, repo.get!(Task, uuid)}
      {:error, changeset} -> {:error, {:trajectory_task_failed, changeset}}
    end
  end

  defp deterministic_uuid(seed) when is_binary(seed) do
    <<b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15>> =
      binary_part(:crypto.hash(:sha256, seed), 0, 16)

    versioned = (b6 &&& 0x0F) ||| 0x50
    variant = (b8 &&& 0x3F) ||| 0x80

    <<c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15>> =
      <<b0, b1, b2, b3, b4, b5, versioned, b7, variant, b9, b10, b11, b12, b13, b14, b15>>

    hex =
      Base.encode16(
        <<c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15>>,
        case: :lower
      )

    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12)>> =
      hex

    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end

  defp terminal_event(repo, goal_id, run_id) do
    repo.one(
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^goal_id and event.run_id == ^run_id and
            event.type in ["run.completed", "run.failed", "run.interrupted", "run.cancelled"],
        order_by: [desc: event.sequence],
        limit: 1
    )
  end

  defp run_resolvable?(repo, goal_id, run_id) do
    case terminal_event(repo, goal_id, run_id) do
      %{type: "run.completed"} -> true
      %{type: "run.failed", payload: payload} -> payload["error_category"] != "quota_refused"
      _ -> false
    end
  end

  defp require_run_terminal(repo, goal_id, run_id) do
    case terminal_event(repo, goal_id, run_id) do
      nil ->
        {:error, {:run_not_terminal, run_id}}

      %{type: "run.completed"} = event ->
        {:ok, event}

      %{type: "run.failed", payload: payload} = event ->
        if payload["error_category"] == "quota_refused",
          do: {:error, {:run_requires_continuation, run_id}},
          else: {:ok, event}

      %{type: type} ->
        {:error, {:run_not_completed, %{run_id: run_id, type: type}}}
    end
  end

  # ----------------------------------------------------------------------------
  # Executor event appends
  # ----------------------------------------------------------------------------

  defp append_executor_event(repo, goal_id, type, payload, idempotency_key, opts) do
    attrs = %{
      "type" => type,
      "schema_version" => @schema_version,
      "actor" => @actor,
      "occurred_at" => now(opts),
      "idempotency_key" => idempotency_key,
      "payload" => payload
    }

    trusted =
      case payload["run_id"] do
        nil ->
          []

        run_id ->
          case repo.get_by(RunRecord, id: run_id, goal_id: goal_id) do
            %RunRecord{task_id: task_id} -> [run_id: run_id, task_id: task_id]
            _ -> [run_id: run_id]
          end
      end

    case Trajectory.append(goal_id, attrs,
           trusted: trusted,
           writer_opts: Keyword.get(opts, :writer_opts, [])
         ) do
      {:ok, event} -> {:ok, event}
      {:error, reason} -> {:error, {:executor_append_failed, type, reason}}
    end
  end

  defp execution_id(attrs, revision_number, digest) do
    case Map.get(attrs, :execution_id) || Map.get(attrs, "execution_id") do
      nil -> deterministic_uuid("plan-execution:#{revision_number}:#{digest}")
      execution_id -> execution_id
    end
  end

  defp refresh_projection(repo, goal_id) do
    {:ok, projection} = project(repo, goal_id)
    projection
  end

  # ----------------------------------------------------------------------------
  # Shared helpers
  # ----------------------------------------------------------------------------

  defp ensure_goal(repo, goal_id) do
    if repo.exists?(from goal in Goal, where: goal.id == ^goal_id) do
      :ok
    else
      {:error, :goal_not_found}
    end
  end

  defp positive_int(attrs, field) do
    value = Map.get(attrs, field) || Map.get(attrs, Atom.to_string(field))

    if is_integer(value) and value > 0 do
      {:ok, value}
    else
      {:error, {:invalid_execution_request, field}}
    end
  end

  defp sha_digest(attrs) do
    value = Map.get(attrs, :digest) || Map.get(attrs, "digest")

    if is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value) do
      {:ok, value}
    else
      {:error, {:invalid_execution_request, :digest}}
    end
  end

  defp cast_goal_id(goal_id) do
    case Ecto.UUID.cast(goal_id) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, {:invalid_goal_id, goal_id}}
    end
  end

  defp cast_uuid(value, field) do
    case Ecto.UUID.cast(value) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, {:invalid_uuid, field}}
    end
  end

  defp now(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = now -> DateTime.truncate(now, :microsecond)
      _other -> DateTime.truncate(DateTime.utc_now(), :microsecond)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
