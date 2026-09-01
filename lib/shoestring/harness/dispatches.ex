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

  @spec enqueue(RunRequest.t(), Identity.t(), keyword()) ::
          {:ok, DispatchRecord.t(), Job.t()} | {:error, term()}
  def enqueue(%RunRequest{} = request, %Identity{} = identity, opts \\ []) do
    with {:ok, run} <- Runs.request(request, identity, opts),
         :ok <- ensure_requested_event(run, opts),
         {:ok, dispatch, job} <- ensure_delivery(run, opts) do
      {:ok, dispatch, job}
    end
  end

  @doc "Repairs every canonical dispatch intent whose linked Oban job is absent."
  @spec reconcile(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def reconcile(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    repo.all(from dispatch in DispatchRecord, order_by: [asc: dispatch.inserted_at])
    |> Enum.reduce_while({:ok, 0}, fn dispatch, {:ok, count} ->
      with :ok <- ensure_requested_event(dispatch, opts),
           {:ok, _dispatch, _job, repaired?} <- ensure_job(dispatch, opts) do
        {:cont, {:ok, count + if(repaired?, do: 1, else: 0)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc false
  @spec prepare_for_effect(Ecto.UUID.t(), keyword()) ::
          {:ok, {:execute, DispatchRecord.t(), RunRecord.t()} | {:skip, atom()}}
          | {:error, term()}
  def prepare_for_effect(dispatch_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, dispatch} <- fetch(dispatch_id, repo),
         {:ok, _repaired} <- Runs.reconcile(dispatch.goal_id, clock_opts(opts)),
         :ok <- ensure_requested_event(dispatch, opts),
         {:ok, result} <- claim_effect(dispatch, repo, opts) do
      {:ok, result}
    end
  end

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
      nil -> create_intent_and_job(run, opts)
      %DispatchRecord{} = dispatch -> ensure_job_result(dispatch, opts)
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
        recover_existing_delivery(run.dispatch_id, opts)

      {:error, _operation, reason, _changes} ->
        {:error, reason}
    end
  end

  defp recover_existing_delivery(dispatch_id, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    case fetch(dispatch_id, repo) do
      {:ok, dispatch} -> ensure_job_result(dispatch, opts)
      error -> error
    end
  end

  defp ensure_job_result(dispatch, opts) do
    case ensure_job(dispatch, opts) do
      {:ok, dispatch, job, _repaired?} -> {:ok, dispatch, job}
      {:error, reason} -> {:error, reason}
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
  defp linked_job(%DispatchRecord{job_id: job_id}, repo), do: repo.get(Job, job_id)

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

      dispatch.status == "requested" ->
        claim_requested_dispatch(dispatch, run, repo, now)

      dispatch.status == "effect_started" ->
        {:skip, :effect_outcome_unknown}

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
