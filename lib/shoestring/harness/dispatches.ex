defmodule Shoestring.Harness.Dispatches do
  @moduledoc "Durable Oban delivery for versioned run intents.

  `harness_dispatches` is the effect truth. Oban jobs are durable delivery
  attempts and uniqueness reduces redundant attempts, but neither determines
  whether an external harness effect may run.
  "

  import Ecto.Query

  alias Ecto.Multi
  alias Oban.Job

  alias Shoestring.Harness.{
    Clock,
    DispatchRecord,
    EventPayload,
    Identity,
    RunRecord,
    RunRequest,
    Runs
  }

  alias Shoestring.Harness.DispatchWorker
  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.TrajectoryEvent

  @reconcilable_dispatch_statuses [
    "requested",
    "effect_started",
    "effect_failed",
    "effect_unknown",
    "effect_deferred"
  ]
  @terminal_dispatch_statuses [
    "effect_failed",
    "effect_unknown",
    "effect_deferred",
    "effect_completed",
    "cancelled"
  ]
  @live_job_states ["available", "scheduled", "executing", "retryable", "suspended"]

  @spec enqueue(RunRequest.t(), Identity.t(), keyword()) ::
          {:ok, DispatchRecord.t(), Job.t() | nil} | {:error, term()}
  def enqueue(%RunRequest{} = request, %Identity{} = identity, opts \\ []) do
    with {:ok, dispatch, job, run, recovered?} <- create_run_and_delivery(request, identity, opts),
         :ok <- Runs.ensure_requested_event(run, request, identity, opts, recovered?),
         :ok <- ensure_requested_event(dispatch, opts) do
      {:ok, dispatch, job}
    end
  end

  defp create_run_and_delivery(request, identity, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    now = now(opts)

    with {:ok, run_changeset} <- Runs.build_intent_changeset(request, identity, opts) do
      Multi.new()
      |> Multi.insert(:run, run_changeset)
      |> Multi.insert(:dispatch, fn %{run: run} ->
        DispatchRecord.intent_changeset(%DispatchRecord{dispatch_id: run.dispatch_id}, run, now)
      end)
      |> Oban.insert(:job, fn %{dispatch: dispatch} -> job_changeset(dispatch, now) end)
      |> Multi.run(:job_link, fn transaction_repo, %{dispatch: dispatch, job: job} ->
        transaction_repo.update(DispatchRecord.job_changeset(dispatch, job.id, now))
      end)
      |> repo.transaction()
      |> case do
        {:ok, %{run: run, job_link: dispatch, job: job}} ->
          {:ok, dispatch, job, run, false}

        {:error, :run, changeset, _changes} ->
          recover_run_and_delivery(repo, changeset, opts)

        {:error, :dispatch, changeset, _changes} ->
          case Runs.recover_existing_run(repo, changeset) do
            {:ok, run} ->
              with {:ok, dispatch, job, _repaired?} <- ensure_delivery(run, opts) do
                {:ok, dispatch, job, run, true}
              end

            {:error, reason} ->
              {:error, reason}
          end

        {:error, _operation, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  defp recover_run_and_delivery(repo, changeset, opts) do
    with {:ok, run} <- Runs.recover_existing_run(repo, changeset),
         {:ok, dispatch, job, _repaired?} <- ensure_delivery(run, opts) do
      {:ok, dispatch, job, run, true}
    end
  end

  @doc "Repairs explicit dispatch intents and requested run-only partial states."
  @spec reconcile(keyword()) ::
          {:ok, %{repaired_count: non_neg_integer(), failures: [map()]}} | {:error, term()}
  def reconcile(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    run_only = run_only_reconciliation_candidates(repo)
    dispatches = dispatch_reconciliation_candidates(repo)
    runs = Enum.uniq_by(run_only ++ Enum.map(dispatches, &elem(&1, 1)), & &1.id)

    result =
      new_reconcile_result()
      |> reconcile_run_goals(runs, opts)
      |> reconcile_dispatches(dispatches, opts)
      |> reconcile_run_only(run_only, opts)
      |> finalize_reconcile_result()

    emit_reconcile_result(result)
    {:ok, result}
  end

  defp run_only_reconciliation_candidates(repo) do
    repo.all(
      from run in RunRecord,
        left_join: dispatch in DispatchRecord,
        on: dispatch.dispatch_id == run.dispatch_id,
        where:
          run.status == "requested" and run.projection_sequence == 0 and
            is_nil(dispatch.dispatch_id),
        order_by: [asc: run.inserted_at]
    )
  end

  defp dispatch_reconciliation_candidates(repo) do
    statuses = @reconcilable_dispatch_statuses

    repo.all(
      from dispatch in DispatchRecord,
        join: run in RunRecord,
        on: run.id == dispatch.run_id and run.goal_id == dispatch.goal_id,
        where: dispatch.status in ^statuses,
        order_by: [asc: dispatch.inserted_at],
        select: {dispatch, run}
    )
  end

  defp reconcile_run_goals(result, runs, opts) do
    Enum.reduce(runs, result, fn run, result ->
      case safe_reconcile_run(run, opts) do
        :ok -> result
        {:ok, :repaired} -> result
        {:error, reason} -> record_failure(result, reconciliation_ids(run), reason)
      end
    end)
  end

  defp reconcile_dispatches(result, dispatches, opts) do
    Enum.reduce(dispatches, result, fn {dispatch, run}, result ->
      case safe_reconcile_dispatch(dispatch, run, opts) do
        {:ok, repaired} -> add_repaired(result, repaired)
        {:error, reason} -> record_failure(result, reconciliation_ids(dispatch), reason)
      end
    end)
  end

  defp reconcile_dispatch(%DispatchRecord{status: "requested"} = dispatch, run, opts) do
    with :ok <- ensure_requested_event(dispatch, opts) do
      if run.status == "requested" do
        case ensure_job(dispatch, opts) do
          {:ok, _dispatch, _job, repaired?} -> {:ok, if(repaired?, do: 1, else: 0)}
          {:error, reason} -> {:error, reason}
        end
      else
        {:ok, 0}
      end
    end
  end

  defp reconcile_dispatch(%DispatchRecord{status: "effect_started"} = dispatch, _run, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    if linked_job(dispatch, repo) do
      {:ok, 0}
    else
      case record_effect_outcome(dispatch.dispatch_id, "effect_unknown", opts) do
        :ok -> {:ok, 1}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp reconcile_dispatch(%DispatchRecord{} = dispatch, _run, opts) do
    repaired? = not outcome_event_exists?(dispatch, opts)

    case append_effect_outcome_event(dispatch, dispatch.status, opts) do
      :ok -> {:ok, if(repaired?, do: 1, else: 0)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile_run_only(result, runs, opts) do
    Enum.reduce(runs, result, fn run, result ->
      case safe_reconcile_run_only(run, opts) do
        {:ok, repaired?} ->
          add_repaired(result, if(repaired?, do: 1, else: 0))

        {:error, reason} ->
          record_failure(result, reconciliation_ids(run), reason)
      end
    end)
  end

  defp safe_reconcile_run(run, opts) do
    try do
      Runs.reconcile_run(run, clock_opts(opts))
    rescue
      _error -> {:error, :reconciliation_failed}
    catch
      _kind, _reason -> {:error, :reconciliation_failed}
    end
  end

  defp safe_reconcile_dispatch(dispatch, run, opts) do
    try do
      reconcile_dispatch(dispatch, run, opts)
    rescue
      _error -> {:error, :reconciliation_failed}
    catch
      _kind, _reason -> {:error, :reconciliation_failed}
    end
  end

  defp safe_reconcile_run_only(run, opts) do
    try do
      with :ok <- ensure_requested_event(run, opts),
           {:ok, _dispatch, _job, repaired?} <- ensure_delivery(run, opts) do
        {:ok, repaired?}
      else
        {:error, reason} -> {:error, reason}
      end
    rescue
      _error -> {:error, :reconciliation_failed}
    catch
      _kind, _reason -> {:error, :reconciliation_failed}
    end
  end

  defp new_reconcile_result do
    %{repaired_count: 0, failures: [], failure_keys: MapSet.new()}
  end

  defp add_repaired(result, count), do: %{result | repaired_count: result.repaired_count + count}

  defp record_failure(result, ids, reason) do
    key = {ids.goal_id, ids.run_id, ids.dispatch_id}

    if MapSet.member?(result.failure_keys, key) do
      result
    else
      %{
        result
        | failures: [Map.put(ids, :reason, sanitize_reconcile_reason(reason)) | result.failures],
          failure_keys: MapSet.put(result.failure_keys, key)
      }
    end
  end

  defp finalize_reconcile_result(result) do
    result
    |> Map.update!(:failures, &Enum.reverse/1)
    |> Map.delete(:failure_keys)
  end

  defp reconciliation_ids(%RunRecord{} = run) do
    %{goal_id: run.goal_id, run_id: run.id, dispatch_id: run.dispatch_id}
  end

  defp reconciliation_ids(%DispatchRecord{} = dispatch) do
    %{goal_id: dispatch.goal_id, run_id: dispatch.run_id, dispatch_id: dispatch.dispatch_id}
  end

  defp sanitize_reconcile_reason(%Shoestring.Harness.Error{code: code}) when is_binary(code),
    do: code

  defp sanitize_reconcile_reason(reason) when is_tuple(reason) do
    case Tuple.to_list(reason) do
      [tag | details] when is_atom(tag) ->
        [Atom.to_string(tag) | Enum.flat_map(details, &safe_reason_detail/1)]
        |> Enum.join(":")

      _other ->
        "reconciliation_failed"
    end
  end

  defp sanitize_reconcile_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp sanitize_reconcile_reason(_reason), do: "reconciliation_failed"

  defp safe_reason_detail(%Shoestring.Harness.Error{code: code}) when is_binary(code), do: [code]
  defp safe_reason_detail(reason) when is_atom(reason), do: [Atom.to_string(reason)]
  defp safe_reason_detail(_reason), do: []

  defp emit_reconcile_result(%{repaired_count: repaired_count, failures: failures}) do
    :telemetry.execute(
      [:shoestring, :harness, :dispatch_reconcile],
      %{repaired_count: repaired_count, failure_count: length(failures)},
      %{result: :ok, repaired_count: repaired_count, failures: failures}
    )
  end

  @doc false
  @spec prepare_for_effect(Ecto.UUID.t(), keyword()) ::
          {:ok, {:execute, DispatchRecord.t(), RunRecord.t()} | {:skip, atom()}}
          | {:error, term()}
  def prepare_for_effect(dispatch_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, dispatch} <- fetch(dispatch_id, repo) do
      case repo.get_by(RunRecord, id: dispatch.run_id, goal_id: dispatch.goal_id) do
        %RunRecord{} = run ->
          with :ok <- reconcile_run_result(Runs.reconcile_run(run, clock_opts(opts))),
               :ok <- ensure_requested_event(dispatch, opts),
               {:ok, result} <- claim_effect(dispatch, repo, opts) do
            {:ok, result}
          end

        nil ->
          {:error, :run_not_found}
      end
    end
  end

  defp reconcile_run_result(:ok), do: :ok
  defp reconcile_run_result({:ok, :repaired}), do: :ok
  defp reconcile_run_result({:error, reason}), do: {:error, reason}

  @doc false
  @spec complete_effect(Ecto.UUID.t(), keyword()) :: :ok | {:error, term()}
  def complete_effect(dispatch_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    now = now(opts)

    case repo.transaction(fn ->
           case repo.get(DispatchRecord, dispatch_id) do
             %DispatchRecord{status: "effect_started"} = dispatch ->
               case repo.update(
                      DispatchRecord.status_changeset(dispatch, "effect_completed", now)
                    ) do
                 {:ok, _dispatch} -> :ok
                 {:error, changeset} -> repo.rollback(changeset)
               end

             %DispatchRecord{status: "effect_completed"} ->
               :ok

             %DispatchRecord{} ->
               repo.rollback(:effect_not_claimed)

             nil ->
               repo.rollback(:dispatch_not_found)
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec record_effect_outcome(Ecto.UUID.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def record_effect_outcome(dispatch_id, status, opts \\ [])
      when status in ["effect_failed", "effect_unknown", "effect_deferred"] do
    repo = Keyword.get(opts, :repo, Repo)
    now = now(opts)

    result =
      repo.transaction(fn ->
        case repo.get(DispatchRecord, dispatch_id) do
          %DispatchRecord{status: ^status} = dispatch ->
            {:ok, dispatch}

          %DispatchRecord{status: "effect_started"} = dispatch ->
            case repo.update(DispatchRecord.outcome_changeset(dispatch, status, now)) do
              {:ok, updated} -> {:ok, updated}
              {:error, changeset} -> repo.rollback(changeset)
            end

          %DispatchRecord{} ->
            repo.rollback(:effect_outcome_not_recordable)

          nil ->
            repo.rollback(:dispatch_not_found)
        end
      end)

    case result do
      {:ok, {:ok, dispatch}} ->
        emit_effect_outcome(dispatch, status)
        append_effect_outcome_event(dispatch, status, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec fetch(Ecto.UUID.t(), module()) ::
          {:ok, DispatchRecord.t()} | {:error, :dispatch_not_found}
  def fetch(dispatch_id, repo \\ Repo) do
    case repo.get(DispatchRecord, dispatch_id) do
      %DispatchRecord{} = dispatch -> {:ok, dispatch}
      nil -> {:error, :dispatch_not_found}
    end
  end

  defp ensure_delivery(run, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    case repo.get(DispatchRecord, run.dispatch_id) do
      nil ->
        case create_intent_and_job(run, opts) do
          {:ok, dispatch, job} -> {:ok, dispatch, job, true}
          error -> error
        end

      %DispatchRecord{} = dispatch ->
        ensure_delivery_for_dispatch(dispatch, opts)
    end
  end

  defp ensure_delivery_for_dispatch(%DispatchRecord{status: "requested"} = dispatch, opts),
    do: ensure_job(dispatch, opts)

  defp ensure_delivery_for_dispatch(
         %DispatchRecord{status: status} = dispatch,
         _opts
       )
       when status in @terminal_dispatch_statuses do
    {:ok, dispatch, nil, false}
  end

  defp ensure_delivery_for_dispatch(%DispatchRecord{} = dispatch, opts) do
    case existing_job(dispatch, Keyword.get(opts, :repo, Repo)) do
      %Job{} = job -> {:ok, dispatch, job, false}
      nil -> {:error, {:dispatch_not_repairable, dispatch.status}}
    end
  end

  defp create_intent_and_job(run, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    now = now(opts)
    dispatch = %DispatchRecord{dispatch_id: run.dispatch_id}

    Multi.new()
    |> Multi.insert(:dispatch, DispatchRecord.intent_changeset(dispatch, run, now))
    |> Oban.insert(:job, fn %{dispatch: dispatch} -> job_changeset(dispatch, now) end)
    |> Multi.run(:job_link, fn transaction_repo, %{dispatch: dispatch, job: job} ->
      transaction_repo.update(DispatchRecord.job_changeset(dispatch, job.id, now))
    end)
    |> repo.transaction()
    |> case do
      {:ok, %{job_link: dispatch, job: job}} ->
        {:ok, dispatch, job}

      {:error, :dispatch, _changeset, _changes} ->
        case recover_existing_delivery(run.dispatch_id, opts) do
          {:ok, dispatch, job, _repaired?} -> {:ok, dispatch, job}
          error -> error
        end

      {:error, _operation, reason, _changes} ->
        {:error, reason}
    end
  end

  defp recover_existing_delivery(dispatch_id, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    case fetch(dispatch_id, repo) do
      {:ok, dispatch} -> ensure_delivery_for_dispatch(dispatch, opts)
      error -> error
    end
  end

  defp ensure_job(dispatch, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    case linked_job(dispatch, repo) do
      %Job{} = job -> {:ok, dispatch, job, false}
      nil -> insert_missing_job(dispatch, opts)
    end
  end

  defp linked_job(%DispatchRecord{job_id: nil}, _repo), do: nil

  defp linked_job(%DispatchRecord{job_id: job_id}, repo) do
    case repo.get(Job, job_id) do
      %Job{state: state} = job when state in @live_job_states -> job
      _job -> nil
    end
  end

  defp existing_job(dispatch, repo), do: linked_job(dispatch, repo)

  defp insert_missing_job(dispatch, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    now = now(opts)

    Multi.new()
    |> Oban.insert(:job, job_changeset(dispatch, now))
    |> Multi.run(:job_link, fn transaction_repo, %{job: job} ->
      dispatch = transaction_repo.get!(DispatchRecord, dispatch.dispatch_id)
      transaction_repo.update(DispatchRecord.job_changeset(dispatch, job.id, now))
    end)
    |> repo.transaction()
    |> case do
      {:ok, %{job_link: repaired, job: job}} -> {:ok, repaired, job, true}
      {:error, _operation, reason, _changes} -> {:error, reason}
    end
  end

  defp claim_effect(dispatch, repo, opts) do
    now = now(opts)

    repo.transaction(fn ->
      with %DispatchRecord{} = dispatch <- repo.get(DispatchRecord, dispatch.dispatch_id),
           :ok <- verify_canonical_intent(dispatch, repo),
           :ok <- verify_run_ownership(dispatch, repo),
           %RunRecord{} = run <-
             repo.get_by(RunRecord, id: dispatch.run_id, goal_id: dispatch.goal_id) do
        claim_effect(dispatch, run, repo, now)
      else
        nil -> repo.rollback(:run_not_found)
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp claim_effect(dispatch, run, repo, now) do
    cond do
      run.status in ["cancelling", "cancelled", "completed", "failed"] ->
        cancel_unstarted_dispatch(dispatch, repo, now)

      run.status == "requested" and dispatch.status == "requested" ->
        claim_requested_dispatch(dispatch, run, repo, now)

      dispatch.status == "requested" ->
        defer_requested_dispatch(dispatch, repo, now)

      dispatch.status == "effect_started" ->
        {:skip, :effect_outcome_unknown}

      dispatch.status == "effect_failed" ->
        {:skip, :effect_failed}

      dispatch.status == "effect_unknown" ->
        {:skip, :effect_unknown}

      dispatch.status == "effect_deferred" ->
        {:skip, :effect_deferred}

      dispatch.status == "effect_completed" ->
        {:skip, :effect_completed}

      dispatch.status == "cancelled" ->
        {:skip, :cancelled}
    end
  end

  defp cancel_unstarted_dispatch(%DispatchRecord{status: "cancelled"}, _repo, _now),
    do: {:skip, :cancelled}

  defp cancel_unstarted_dispatch(%DispatchRecord{status: "requested"} = dispatch, repo, now) do
    case repo.update(DispatchRecord.status_changeset(dispatch, "cancelled", now)) do
      {:ok, _dispatch} -> {:skip, :cancelled}
      {:error, changeset} -> repo.rollback(changeset)
    end
  end

  defp cancel_unstarted_dispatch(%DispatchRecord{status: "effect_started"}, _repo, _now),
    do: {:skip, :effect_outcome_unknown}

  defp cancel_unstarted_dispatch(%DispatchRecord{status: "effect_completed"}, _repo, _now),
    do: {:skip, :effect_completed}

  defp cancel_unstarted_dispatch(%DispatchRecord{status: "effect_failed"}, _repo, _now),
    do: {:skip, :effect_failed}

  defp cancel_unstarted_dispatch(%DispatchRecord{status: "effect_unknown"}, _repo, _now),
    do: {:skip, :effect_unknown}

  defp cancel_unstarted_dispatch(%DispatchRecord{status: "effect_deferred"}, _repo, _now),
    do: {:skip, :effect_deferred}

  defp defer_requested_dispatch(%DispatchRecord{status: "requested"} = dispatch, repo, now) do
    case repo.update(
           DispatchRecord.outcome_changeset(
             dispatch,
             "effect_deferred",
             now,
             "run_state_advanced"
           )
         ) do
      {:ok, _dispatch} -> {:skip, :effect_deferred}
      {:error, changeset} -> repo.rollback(changeset)
    end
  end

  defp claim_requested_dispatch(dispatch, run, repo, now) do
    {claimed, _rows} =
      repo.update_all(
        from(candidate in DispatchRecord,
          where:
            candidate.dispatch_id == ^dispatch.dispatch_id and candidate.status == "requested"
        ),
        set: [status: "effect_started", updated_at: now]
      )

    if claimed == 1 do
      {:execute, %{dispatch | status: "effect_started", updated_at: now}, run}
    else
      {:skip, :claimed_by_another_delivery}
    end
  end

  defp ensure_requested_event(%RunRecord{} = run, opts) do
    append_requested_event(
      run.goal_id,
      run.task_id,
      run.id,
      run.dispatch_id,
      run.request_version,
      opts
    )
  end

  defp ensure_requested_event(%DispatchRecord{} = dispatch, opts) do
    append_requested_event(
      dispatch.goal_id,
      dispatch.task_id,
      dispatch.run_id,
      dispatch.dispatch_id,
      dispatch.request_version,
      opts
    )
  end

  defp append_requested_event(goal_id, task_id, run_id, dispatch_id, request_version, opts) do
    attrs = %{
      "type" => "dispatch.requested",
      "schema_version" => 1,
      "actor" => "harness",
      "occurred_at" => now(opts),
      "idempotency_key" => "dispatch-requested:#{dispatch_id}",
      "payload" =>
        EventPayload.dispatch_requested(%{
          dispatch_id: dispatch_id,
          run_id: run_id,
          request_version: request_version
        })
    }

    case Trajectory.append(goal_id, attrs,
           trusted: [task_id: task_id, run_id: run_id],
           writer_opts: Keyword.get(opts, :writer_opts, [])
         ) do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_effect_outcome_event(dispatch, status, opts) do
    if outcome_event_exists?(dispatch, opts) do
      :ok
    else
      type = outcome_event_type(status)

      attrs = %{
        "type" => type,
        "schema_version" => 1,
        "actor" => "harness",
        "occurred_at" => now(opts),
        "idempotency_key" => outcome_idempotency_key(status, dispatch.dispatch_id),
        "payload" => %{
          "dispatch_id" => dispatch.dispatch_id,
          "run_id" => dispatch.run_id,
          "error_code" => dispatch.outcome_code || status
        }
      }

      case Trajectory.append(dispatch.goal_id, attrs,
             trusted: [task_id: dispatch.task_id, run_id: dispatch.run_id],
             writer_opts: Keyword.get(opts, :writer_opts, [])
           ) do
        {:ok, _event} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp outcome_event_exists?(dispatch, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    status = dispatch.status

    repo.exists?(
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^dispatch.goal_id and
            event.run_id == ^dispatch.run_id and
            event.type == ^outcome_event_type(status) and
            event.idempotency_key == ^outcome_idempotency_key(status, dispatch.dispatch_id)
    )
  end

  defp outcome_event_type("effect_failed"), do: "dispatch.effect_failed"
  defp outcome_event_type("effect_unknown"), do: "dispatch.effect_unknown"
  defp outcome_event_type("effect_deferred"), do: "dispatch.effect_deferred"

  defp outcome_idempotency_key(status, dispatch_id),
    do: "dispatch-#{String.replace(status, "_", "-")}:#{dispatch_id}"

  defp emit_effect_outcome(dispatch, status) do
    :telemetry.execute(
      [:shoestring, :harness, :dispatch_outcome],
      %{count: 1},
      %{
        dispatch_id: dispatch.dispatch_id,
        run_id: dispatch.run_id,
        outcome: status,
        error_code: dispatch.outcome_code || status
      }
    )
  end

  defp verify_canonical_intent(dispatch, repo) do
    if repo.exists?(
         from event in TrajectoryEvent,
           where:
             event.goal_id == ^dispatch.goal_id and
               event.run_id == ^dispatch.run_id and
               event.type == "dispatch.requested" and
               event.idempotency_key == ^"dispatch-requested:#{dispatch.dispatch_id}"
       ) do
      :ok
    else
      {:error, :dispatch_intent_missing}
    end
  end

  defp verify_run_ownership(dispatch, repo) do
    if Runs.owned?(dispatch.goal_id, dispatch.run_id, repo) do
      :ok
    else
      {:error, :run_not_owned}
    end
  end

  defp job_args(dispatch) do
    %{
      "dispatch_id" => dispatch.dispatch_id,
      "goal_id" => dispatch.goal_id,
      "run_id" => dispatch.run_id,
      "request_version" => dispatch.request_version
    }
  end

  defp job_changeset(dispatch, now) do
    DispatchWorker.new(job_args(dispatch), scheduled_at: now, inserted_at: now)
  end

  defp clock_opts(opts), do: Keyword.put_new(opts, :clock, dispatch_clock())
  defp now(opts), do: Clock.now(Keyword.get(opts, :clock, dispatch_clock()))

  defp dispatch_clock do
    Application.get_env(:shoestring, :dispatch_clock, Shoestring.Harness.SystemClock)
  end
end
