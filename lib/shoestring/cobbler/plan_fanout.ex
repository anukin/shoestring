defmodule Shoestring.Cobbler.PlanFanout do
  @moduledoc """
  Internal version-1 coordinator for initial sibling attempts. Not selected by
  production workers. Trusted callers explicitly enable it and supply a policy
  and per-task admission function; no plan field activates fan-out.

  Iterates ready tasks in declared topological order, skipping blocked providers.
  Each child commits its own reservation/intent atomically. Completed branches
  are retained; dependency outputs must already exist at the approved base.
  This boundary neither merges branches nor retries failed attempts.
  """
  alias Shoestring.Cobbler.{PlanBudget, PlanContract, PlanDispatch, PlanExecutor}
  alias Shoestring.Cobbler.{PlanIndependence, Plans, PlanSiblingWorkspace, ReservationPolicy}
  alias Shoestring.Cobbler.{PlanBinding, ReservationRecord, Reservations, ScopeEvidence}
  alias Shoestring.Harness.RunRecord
  alias Shoestring.{Repo, Trajectory, Worktrees}

  def dispatch_ready(goal_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with :ok <- configuration(opts),
         {:ok, policy} <- policy(opts),
         :ok <-
           Reservations.reconcile_terminals(
             goal_id,
             Keyword.merge(Keyword.get(opts, :reconciliation_opts, []),
               repo: repo,
               now: now(opts)
             )
           ),
         {:ok, context} <- context(goal_id, opts),
         :ok <- no_scope_conflicts(context),
         {:ok, assessment} <- assess(context, opts),
         {:ok, _} <- record(context, assessment, opts) do
      if assessment.decision["disposition"] != "eligible" do
        {:ok,
         %{
           disposition: :blocked,
           reason: :independence_unverified,
           decision: assessment.decision,
           dispatched: [],
           blocked: []
         }}
      else
        results =
          Enum.reduce(context.ready, %{dispatched: [], blocked: []}, fn task, results ->
            case dispatch_one(context, task, policy, opts) do
              {:ok, child} ->
                %{results | dispatched: results.dispatched ++ [child]}

              {:error, reason} ->
                %{
                  results
                  | blocked: results.blocked ++ [%{plan_task_id: task["id"], reason: reason}]
                }
            end
          end)

        {:ok,
         Map.merge(results, %{
           disposition:
             cond do
               results.dispatched != [] -> :dispatched
               results.blocked != [] -> :blocked
               true -> :awaiting_tasks
             end,
           execution: context.status.execution,
           queue_policy_version: 1
         })}
      end
    end
  end

  @doc false
  def authorize(goal_id, task_id, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    with true <- repo.in_transaction?() || {:error, :reservation_transaction_required},
         :ok <- configuration(opts),
         {:ok, context} <- context(goal_id, opts),
         :ok <- no_scope_conflicts(context),
         task when not is_nil(task) <- Enum.find(context.ready, &(&1["id"] == task_id)),
         :ok <- inputs_at_base(context, task),
         {:ok, assessment} <- assess(context, opts),
         true <- assessment.decision["disposition"] == "eligible",
         :ok <- budget(context, task, opts),
         {:ok, prepared} <-
           PlanSiblingWorkspace.prepare(
             goal_id,
             context.status.execution,
             task_id,
             1,
             Keyword.put(opts, :repository_path, context.source)
           ),
         true <- prepared.worktree.workspace_ref == Keyword.get(opts, :workspace_ref),
         {:ok, _} <- record(context, assessment, opts) do
      :ok
    else
      nil -> {:error, :fanout_task_not_ready}
      false -> {:error, :independence_unverified}
      error -> error
    end
  end

  @doc false
  def require_quiescent(goal_id, child, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    with :ok <-
           Reservations.reconcile_terminals(
             goal_id,
             Keyword.merge(Keyword.get(opts, :reconciliation_opts, []),
               repo: repo,
               now: now(opts)
             )
           ),
         %ReservationRecord{} = owner <- repo.get_by(ReservationRecord, run_id: child.run_id),
         %{kind: "consumed_closed"} <-
           repo.get(Shoestring.Cobbler.ReservationSettlementRecord, owner.id) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :fanout_child_not_quiescent}
    end
  end

  @doc false
  def final_scope(goal_id, execution, child, evidences, opts) do
    commit = hd(evidences).commit

    with true <- Enum.all?(evidences, &(&1.commit == commit)),
         {:ok, context} <- context(goal_id, opts),
         true <- context.status.execution == execution,
         {:ok, tree} <- Worktrees.get(child.root_run_id, opts),
         {:ok, files} <- ScopeEvidence.final_changes(tree.path, context.base, commit),
         {:ok, scope_json} <-
           Shoestring.Cobbler.PlanFinalScope.encode(
             context.base,
             commit,
             child.root_run_id,
             files
           ),
         {:ok, assessment} <- assess(context, opts),
         # The assessment itself must not race movement of the tested child.
         {:ok, ^files} <- ScopeEvidence.final_changes(tree.path, context.base, commit) do
      decision = final_decision(assessment.decision, child.plan_task_id)

      # A bounded file set can still exceed the event JSON byte bound when its
      # paths are long. Preserve gate evidence as an explicit unverified result
      # rather than discovering that overflow while appending the final event.
      with {:ok, _} <-
             PlanIndependence.decode_event_decision(PlanContract.canonical_json(decision)) do
        {:ok, scope_json, decision}
      end
    else
      false -> {:error, :fanout_final_snapshot_changed}
      error -> error
    end
  end

  defp final_decision(decision, task_id) do
    # A complete decision lets an unaffected child retain its own acceptance.
    # Truncated evidence cannot establish that the omitted blockers are unrelated.
    if decision["evidence_complete"] do
      blockers =
        Enum.filter(decision["blockers"], fn blocker ->
          case {blocker["task_id"], blocker["task_ids"]} do
            {nil, nil} -> true
            {^task_id, _} -> true
            {_, ids} when is_list(ids) -> task_id in ids
            _ -> false
          end
        end)

      %{
        decision
        | "source" => "actual",
          "blockers" => blockers,
          "blocker_count" => length(blockers),
          "disposition" => if(blockers == [], do: "eligible", else: "sequential")
      }
    else
      Map.put(decision, "source", "actual")
    end
  end

  defp no_scope_conflicts(context) do
    if context.status.scope_blockers == [],
      do: :ok,
      else: {:error, :fanout_scope_resolution_required}
  end

  defp configuration(opts) do
    if Keyword.get(opts, :fanout_enabled) == true and
         is_function(Keyword.get(opts, :admission_fun), 4),
       do: :ok,
       else: {:error, :fanout_configuration_required}
  end

  defp policy(opts) do
    case Keyword.get(opts, :reservation_policy) do
      %ReservationPolicy{} = policy -> ReservationPolicy.new(ReservationPolicy.to_map(policy))
      policy when is_map(policy) -> ReservationPolicy.new(policy)
      _ -> {:error, :fanout_reservation_policy_required}
    end
  end

  defp context(goal_id, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, %{execution: execution, completed?: false, global_failure: nil} = status} <-
           PlanExecutor.status(goal_id, opts),
         %{revision: revision} <- Plans.authority(goal_id, repo: repo),
         true <-
           revision.digest == execution.plan_digest and
             revision.revision_number == execution.revision_number,
         {:ok, contract} <- PlanContract.new(revision.content),
         true <- status.children == [] or status.dispatch_mode == :fanout_v1,
         source when is_binary(source) <-
           execution[:repository_path] || Keyword.get(opts, :repository_path),
         true <-
           is_nil(execution[:repository_path]) or is_nil(Keyword.get(opts, :repository_path)) or
             Path.expand(source) == Path.expand(Keyword.fetch!(opts, :repository_path)) do
      by_id = Map.new(contract.content["tasks"], &{&1["id"], &1})

      ready =
        PlanContract.required_task_ids(contract)
        |> Enum.map(&Map.fetch!(by_id, &1))
        |> Enum.filter(fn task ->
          Map.get(status.attempts, task["id"], 0) == 0 and task["id"] not in status.accepted and
            Enum.all?(task["depends_on"], &(&1 in status.accepted))
        end)

      {:ok,
       %{
         goal_id: goal_id,
         status: status,
         contract: contract,
         ready: ready,
         source: source,
         base: get_in(contract.content, ["goal", "repository", "base_revision"]),
         by_id: by_id
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :fanout_execution_authority_required}
    end
  end

  defp assess(context, opts) do
    tasks =
      (Enum.map(context.status.children, &Map.fetch!(context.by_id, &1.plan_task_id)) ++
         context.ready)
      |> Enum.uniq_by(& &1["id"])

    with {:ok, metadata} <- ScopeEvidence.repository(context.source, context.base),
         {:ok, changes} <- observed_changes(context, opts) do
      declared = PlanIndependence.declared(tasks, metadata)
      actual = PlanIndependence.actual(changes, metadata)

      outside =
        Enum.flat_map(changes, fn {id, files} ->
          hints = context.by_id[id]["hints"]["files"]

          for file <- files,
              not Enum.any?(hints, &within?(file, &1)),
              do: %{"task_id" => id, "reason" => "outside_declared_scope", "path" => file}
        end)

      blockers = Enum.sort(Enum.uniq(declared["blockers"] ++ actual["blockers"] ++ outside))
      count = declared["blocker_count"] + actual["blocker_count"] + length(outside)
      # An empty ready/child set is an idle coordinator, not unknown scope.
      decision =
        if tasks == [],
          do: %{declared | "disposition" => "eligible", "blockers" => [], "blocker_count" => 0},
          else: %{
            declared
            | "disposition" => if(count == 0, do: "eligible", else: "sequential"),
              "blocker_count" => count,
              "blockers" => Enum.take(blockers, 128),
              "evidence_complete" =>
                declared["evidence_complete"] and actual["evidence_complete"] and count <= 128
          }

      decision = Map.put(decision, "observed_changes", changes)
      {:ok, %{decision: decision}}
    end
  end

  defp observed_changes(context, opts) do
    Enum.reduce_while(context.status.children, {:ok, %{}}, fn child, {:ok, acc} ->
      binding = %{
        "execution_id" => context.status.execution.execution_id,
        "revision_number" => context.status.execution.revision_number,
        "plan_digest" => context.status.execution.plan_digest,
        "plan_task_id" => child.plan_task_id,
        "attempt" => child.attempt
      }

      metadata = %{
        "goal_id" => context.goal_id,
        PlanBinding.key() => binding,
        "shoestring.fanout:accepted_base" => context.base,
        "shoestring.fanout:version" => 1
      }

      with :ok <- child_ownership(context, child, opts),
           true <-
             child.root_run_id ==
               PlanExecutor.task_run_id(context.goal_id, child.plan_task_id, child.attempt),
           {:ok, tree} <- Worktrees.get(child.root_run_id, opts),
           true <-
             PlanSiblingWorkspace.bound?(tree, child.root_run_id, context.base, metadata, opts),
           {:ok, files} <- child_changes(context, child, tree, opts) do
        {:cont, {:ok, Map.put(acc, child.plan_task_id, files)}}
      else
        _ -> {:halt, {:error, :fanout_child_scope_unavailable}}
      end
    end)
  end

  defp child_changes(context, child, tree, _opts) do
    accepted =
      Enum.find(context.status.accepted_evidence, fn evidence ->
        evidence.execution_id == child.execution_id and
          evidence.plan_task_id == child.plan_task_id and
          evidence.attempt == child.attempt
      end)

    if accepted do
      # Even historical accepted children without final scope JSON must stay at
      # their tested commit. A mutable branch cannot rewrite accepted evidence.
      ScopeEvidence.final_changes(tree.path, context.base, accepted.commit)
    else
      ScopeEvidence.changes(tree.path, context.base)
    end
  end

  defp child_ownership(context, child, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    valid? =
      Enum.all?(Enum.uniq([child.root_run_id, child.run_id]), fn id ->
        with %RunRecord{} = run <- repo.get(RunRecord, id),
             %ReservationRecord{} = owner <- repo.get_by(ReservationRecord, run_id: id) do
          owner.goal_id == context.goal_id and owner.execution_id == child.execution_id and
            owner.plan_task_id == child.plan_task_id and owner.attempt == child.attempt and
            run.extensions[Reservations.key()] == owner.id and
            run.extensions["shoestring.fanout:version"] == 1
        else
          _ -> false
        end
      end)

    if valid?, do: :ok, else: {:error, :fanout_child_ownership_unknown}
  end

  defp within?(file, hint) do
    normalize = fn path ->
      path |> String.trim_trailing("/") |> String.normalize(:nfc) |> String.downcase()
    end

    file = normalize.(file)
    hint = normalize.(hint)
    file == hint or String.starts_with?(file, hint <> "/")
  end

  defp inputs_at_base(context, task) do
    evidence =
      Enum.filter(context.status.accepted_evidence, &(&1.plan_task_id in task["depends_on"]))

    case Shoestring.Cobbler.PlanWorkspace.require_integrated(
           context.source,
           evidence,
           context.base
         ) do
      :ok -> :ok
      _ -> {:error, :fanout_inputs_require_integration}
    end
  end

  defp dispatch_one(context, task, policy, opts) do
    with :ok <- inputs_at_base(context, task),
         {:ok, admission_id} <-
           Keyword.fetch!(opts, :admission_fun).(
             context.goal_id,
             context.status.execution,
             task,
             1
           ) do
      run_id = PlanExecutor.task_run_id(context.goal_id, task["id"], 1)

      attrs = %{
        id: PlanExecutor.task_reservation_id(context.goal_id, task["id"], 1),
        goal_id: context.goal_id,
        execution_id: context.status.execution.execution_id,
        plan_task_id: task["id"],
        attempt: 1,
        run_id: run_id,
        admission_event_id: admission_id
      }

      opts =
        Keyword.merge(opts,
          reservation_policy: policy,
          admission_event_id: admission_id,
          workspace_ref: "run-#{run_id}",
          repository_path: context.source,
          now: now(opts)
        )

      PlanDispatch.run(
        attrs,
        opts,
        &PlanExecutor.dispatch_sibling(context.goal_id, task["id"], &1)
      )
    end
  end

  defp budget(context, task, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, usage} <- PlanBudget.usage(repo, context.goal_id, now(opts)),
         {:ok, remaining} <- PlanBudget.remaining(usage, context.contract, task) do
      owners =
        Reservations.outstanding(repo: repo) |> Enum.filter(&(&1.goal_id == context.goal_id))

      timeout = Keyword.get(Keyword.get(opts, :gate_runner_opts, []), :timeout_ms, 120_000)

      owner = Enum.find(owners, &(&1.id == Keyword.get(opts, :reservation_id)))

      if not (is_integer(timeout) and timeout > 0),
        do: {:error, :invalid_global_gate_timeout},
        else:
          with(
            :ok <- lease_duration(owner, remaining, now(opts)),
            do: duration_allowance(context, usage, owners, timeout)
          )
    end
  end

  defp lease_duration(owner, remaining, now) do
    with %{} <- owner,
         {:ok, deadline, _} <- DateTime.from_iso8601(owner.lease_bounds["deadline"]),
         duration = DateTime.diff(deadline, now, :millisecond),
         true <- duration > 0 and duration <= remaining do
      :ok
    else
      _ -> {:error, :fanout_lease_exceeds_task_budget}
    end
  end

  defp duration_allowance(context, usage, owners, timeout) do
    valid? =
      Enum.all?(
        owners,
        &(&1.execution_id == context.status.execution.execution_id and
            Map.has_key?(context.by_id, &1.plan_task_id))
      )

    if valid? do
      allowances =
        Enum.map(owners, fn owner ->
          task = context.by_id[owner.plan_task_id]

          task["execution"]["max_duration_seconds"] * 1000 -
            Map.get(usage.task_duration_ms, owner.plan_task_id, 0)
        end)

      # Worst-case verification still owed: every global gate at its command
      # timeout, plus one bounded final-scope observation per held owner. The
      # child count cannot exceed the plan's lifetime attempt limit.
      children = context.contract.content["budget"]["max_total_attempts"]

      verification =
        length(context.contract.content["goal"]["acceptance"]["gates"]) * timeout +
          length(owners) * ScopeEvidence.final_scope_bound_ms(children)

      cond do
        Enum.any?(allowances, &(&1 <= 0)) ->
          {:error, :fanout_duration_owner_exhausted}

        Enum.sum(allowances) + verification <=
            PlanBudget.global_remaining(usage, context.contract) ->
          :ok

        true ->
          {:error, :fanout_duration_allowance_exhausted}
      end
    else
      {:error, :fanout_duration_owner_unknown}
    end
  end

  defp record(context, assessment, opts) do
    payload = %{
      "execution_id" => context.status.execution.execution_id,
      "revision_number" => context.status.execution.revision_number,
      "plan_digest" => context.status.execution.plan_digest,
      "accepted_base" => context.base,
      "repository_observation" => "verified_accepted_base",
      "decision" => assessment.decision
    }

    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(payload, [:deterministic]))
      |> Base.encode16(case: :lower)

    with {:ok, stored_payload} <- PlanIndependence.event_payload(payload) do
      Trajectory.append(
        context.goal_id,
        %{
          "type" => "cobbler.plan.independence.evaluated",
          "schema_version" => 2,
          "actor" => "cobbler",
          "occurred_at" => now(opts),
          "idempotency_key" => "fanout-independence-v2:#{digest}",
          "payload" => stored_payload
        },
        writer_opts: Keyword.get(opts, :writer_opts, [])
      )
    end
  end

  defp now(opts), do: Keyword.get(opts, :now, DateTime.utc_now())
end
