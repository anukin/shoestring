defmodule Shoestring.Cobbler.ExecutionControl do
  @moduledoc "Durable CLI execution requests. Jobs carry identifiers; trajectory owns authority."
  import Ecto.Query
  alias Shoestring.Cobbler.{PlanExecutor, PlanExecutionWorker, WakeupObserve}
  alias Shoestring.Repo
  alias Shoestring.Trajectory.TrajectoryEvent

  def status(goal_id) do
    with {:ok, status} <- PlanExecutor.status(goal_id) do
      decision =
        Repo.one(
          from e in TrajectoryEvent,
            where: e.goal_id == ^goal_id and e.type == "admission.decided",
            order_by: [desc: e.sequence],
            limit: 1
        )

      {:ok,
       Map.merge(status, %{
         last_admission: if(decision, do: decision.payload),
         active_continuation: active_continuation(goal_id, status[:active_run_id]),
         capacity_observation: capacity_observation(Map.get(status, :execution))
       })}
    end
  end

  defp active_continuation(_goal_id, nil), do: nil

  defp active_continuation(goal_id, run_id) do
    run = Repo.get!(Shoestring.Harness.RunRecord, run_id)

    checkpoint =
      Repo.one(
        from e in TrajectoryEvent,
          where: e.goal_id == ^goal_id and e.run_id == ^run_id and e.type == "checkpoint.created",
          order_by: [desc: e.sequence],
          limit: 1
      )

    %{
      run_id: run_id,
      checkpoint_id: checkpoint && checkpoint.payload["checkpoint_id"],
      decision_refs: Shoestring.Harness.Continuation.decision_refs(Repo, goal_id),
      agent_profile: run.extensions[Shoestring.Cobbler.ExecutionProfile.key()],
      provider_id: run.provider_id
    }
  end

  # Repair delivery only. The same canonical intent, approval, counters and
  # active run remain authoritative; a boot never creates a new execution.
  def reconcile(opts \\ []) do
    requests =
      Repo.all(
        from e in TrajectoryEvent,
          where: e.type == "cobbler.plan.execution.requested",
          order_by: [asc: e.sequence]
      )
      |> Enum.reduce(%{}, fn event, acc -> Map.put(acc, event.goal_id, event.payload) end)

    result =
      Enum.reduce(requests, %{repaired_count: 0, failures: []}, fn {goal_id, request}, acc ->
        if is_binary(request["repository_path"]) and is_map(request["agent_profile"]) do
          case continue(goal_id, request["execution_id"], opts) do
            {:ok, %{repaired?: true}} -> Map.update!(acc, :repaired_count, &(&1 + 1))
            {:ok, _} -> acc
            {:error, _} -> Map.update!(acc, :failures, &[goal_id | &1])
          end
        else
          acc
        end
      end)

    {:ok, result}
  end

  def start(goal_id, attrs, opts \\ []) do
    with {:ok, path} <- repository(attrs[:repository_path]),
         {:ok, by} <- human(attrs[:requested_by]) do
      attrs = Map.merge(attrs, %{repository_path: path, requested_by: by})

      Repo.transaction(
        fn ->
          case PlanExecutor.request_execution(
                 goal_id,
                 attrs,
                 Keyword.merge(opts, defer_admission: true, publish_fun: fn _ -> :ok end)
               ) do
            {:ok, result} ->
              job = enqueue!(goal_id, result.execution.execution_id, opts)
              Map.put(result, :job_id, job.id)

            {:error, reason} ->
              Repo.rollback(reason)
          end
        end,
        mode: :immediate
      )
    end
  end

  def continue(goal_id, execution_id, opts \\ []) do
    with {:ok, status} <- PlanExecutor.status(goal_id),
         %{execution: %{execution_id: ^execution_id, repository_path: _}} <- status do
      cond do
        status.completed? ->
          {:ok, %{outcome: :completed, job_id: nil}}

        status.needs_user? ->
          {:ok, %{outcome: :needs_user, job_id: nil}}

        true ->
          Repo.transaction(
            fn ->
              job = enqueue!(goal_id, execution_id, opts)
              %{outcome: :queued, job_id: job.id, repaired?: not job.conflict?}
            end,
            mode: :immediate
          )
      end
    else
      _ -> {:error, :execution_request_mismatch}
    end
  end

  # Queue only an exact checkpoint transfer. The receiver is resolved from the
  # sender's immutable agent revision; the CLI cannot supply a model override.
  def handoff(goal_id, attrs, opts \\ []) do
    with {:ok, by} <- human(attrs[:requested_by]),
         {:ok, run_id} <- Ecto.UUID.cast(attrs[:run_id]),
         {:ok, status} <- PlanExecutor.status(goal_id),
         %{execution_id: execution_id} <- status[:execution],
         true <- execution_id == attrs[:execution_id],
         true <-
           status.active_run_id == attrs[:run_id] or handoff_replay?(goal_id, attrs[:command_id]),
         %Shoestring.Harness.RunRecord{} = sender <-
           Repo.get(Shoestring.Harness.RunRecord, run_id),
         true <- sender.goal_id == goal_id,
         true <-
           get_in(sender.extensions, [Shoestring.Cobbler.PlanBinding.key(), "execution_id"]) ==
             execution_id,
         %{} = pinned <- sender.extensions[Shoestring.Cobbler.ExecutionProfile.key()],
         {:ok, receiver} <-
           Shoestring.Cobbler.ExecutionProfile.resolve(
             Map.put(pinned, "role", attrs[:receiver_role]),
             Repo
           ) do
      payload = %{
        "run_id" => sender.id,
        "checkpoint_id" => attrs[:checkpoint_id],
        "decision_refs" => attrs[:decision_refs],
        "receiver_role" => receiver["role"],
        "to_provider_id" => receiver["provider"],
        "to_adapter_id" => receiver["adapter_id"],
        "scope" => attrs[:scope],
        "reason" => attrs[:reason],
        "requested_by" => by
      }

      payload =
        if attrs[:confirm_capacity],
          do: Map.put(payload, "confirmation", %{"intent" => "supervised_execution"}),
          else: payload

      case Shoestring.Cobbler.Handoffs.request(
             goal_id,
             %{"command_id" => attrs[:command_id], "payload" => payload},
             opts
           ) do
        {:ok, result} ->
          {:ok,
           %{
             outcome: result.outcome,
             handoff_id: result.handoff_id,
             command: Map.take(result.command, [:id, :command_id, :digest, :status, :result]),
             job_id: result.job && result.job.id
           }}

        error ->
          error
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :handoff_execution_request_mismatch}
    end
  end

  defp handoff_replay?(goal_id, command_id) when is_binary(command_id) do
    Repo.exists?(
      from e in TrajectoryEvent,
        where:
          e.goal_id == ^goal_id and e.type == "cobbler.command.accepted" and
            fragment("json_extract(?, '$.command_id')", e.payload) == ^command_id and
            fragment("json_extract(?, '$.command_type')", e.payload) == "run.handoff"
    )
  end

  defp handoff_replay?(_, _), do: false

  defp capacity_observation(%{agent_profile: profile}) do
    scope = Application.get_env(:shoestring, :run_submission_scope, "subscription")
    identity = %{provider_id: profile["provider"], scope: scope}

    case WakeupObserve.observe(identity) do
      {:ok, snapshot} ->
        Map.merge(identity, %{
          source: :cached_observatory,
          availability: :recorded,
          observed_at: snapshot.observed_at
        })

      {:error, reason} ->
        Map.merge(identity, %{source: :cached_observatory, availability: :missing, reason: reason})
    end
  end

  defp capacity_observation(_), do: nil

  def request(goal_id, execution_id) do
    Repo.one(
      from e in TrajectoryEvent,
        where: e.goal_id == ^goal_id and e.type == "cobbler.plan.execution.requested",
        order_by: [desc: e.sequence],
        limit: 1
    )
    |> case do
      %{
        payload:
          %{"execution_id" => ^execution_id, "repository_path" => _, "agent_profile" => _} =
              payload
      } ->
        {:ok, payload}

      _ ->
        {:error, :execution_request_mismatch}
    end
  end

  defp enqueue!(goal_id, execution_id, opts) do
    %{goal_id: goal_id, execution_id: execution_id}
    |> PlanExecutionWorker.new()
    |> then(&Oban.insert(Keyword.get(opts, :oban, Oban), &1))
    |> case do
      {:ok, job} -> job
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp human("human:" <> name = by) do
    if String.trim(name) != "" and byte_size(by) <= 200 and
         Shoestring.Harness.Contract.safe_term?(by),
       do: {:ok, by},
       else: {:error, :human_execution_identity_required}
  end

  defp human(_), do: {:error, :human_execution_identity_required}

  defp repository(path) when is_binary(path) and byte_size(path) > 0 do
    with true <- Shoestring.Harness.Contract.safe_term?(path),
         {:ok, canonical} <-
           Shoestring.Worktrees.Git.validate_repo(
             path,
             Shoestring.Harness.Capacity.SystemCommandRunner
           ) do
      {:ok, canonical}
    else
      _ -> {:error, :execution_repository_invalid}
    end
  end

  defp repository(_), do: {:error, :execution_repository_invalid}
end
