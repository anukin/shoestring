defmodule Shoestring.Cobbler.PlanSiblingWorkspace do
  @moduledoc "Pinned independent sibling storage. Preparation is inert and preserves refused allocations."
  alias Shoestring.Cobbler.{PlanBinding, PlanContract, PlanExecutor, Plans, ScopeEvidence}
  alias Shoestring.Harness.RunRecord
  alias Shoestring.{Repo, Trajectory, Worktrees}

  def prepare(goal_id, execution, task_id, attempt, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    with %{revision: revision} <- Plans.authority(goal_id, repo: repo),
         true <-
           revision.digest == execution.plan_digest and
             revision.revision_number == execution.revision_number,
         true <- is_integer(attempt) and attempt > 0,
         {:ok, contract} <- PlanContract.new(revision.content),
         true <- task_id in PlanContract.required_task_ids(contract),
         {:ok, %{execution: current} = status} <- PlanExecutor.status(goal_id, opts),
         true <- current.execution_id == execution.execution_id,
         task = Enum.find(contract.content["tasks"], &(&1["id"] == task_id)),
         true <- Enum.all?(task["depends_on"], &(&1 in status.accepted)),
         true <- attempt <= task["execution"]["max_attempts"],
         true <-
           attempt == Map.get(status.attempts, task_id, 0) + 1 or
             not is_nil(repo.get(RunRecord, PlanExecutor.task_run_id(goal_id, task_id, attempt))),
         source when is_binary(source) <- Keyword.get(opts, :repository_path) do
      binding = %{
        "execution_id" => execution.execution_id,
        "revision_number" => execution.revision_number,
        "plan_digest" => execution.plan_digest,
        "plan_task_id" => task_id,
        "attempt" => attempt
      }

      base = get_in(contract.content, ["goal", "repository", "base_revision"])
      run_id = PlanExecutor.task_run_id(goal_id, task_id, attempt)

      metadata = %{
        "goal_id" => goal_id,
        "shoestring.plan:binding" => binding,
        "shoestring.fanout:accepted_base" => base,
        "shoestring.fanout:version" => 1
      }

      storage_opts = Keyword.take(opts, [:worktrees_dir])

      with {:ok, worktree} <- allocate(repo, source, run_id, base, metadata, storage_opts),
           {:ok, event} <- record(repo, goal_id, binding, worktree, base, opts) do
        {:ok, %{run_id: run_id, worktree: worktree, event_id: event.id}}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :sibling_workspace_authority_mismatch}
    end
  end

  defp allocate(repo, source, run_id, base, metadata, opts) do
    case Worktrees.get(run_id, opts) do
      {:ok, worktree} ->
        if bound?(worktree, run_id, base, metadata, opts) do
          case repo.get(RunRecord, run_id) do
            nil ->
              with {:ok, _} <- ScopeEvidence.repository(source, base),
                   {:ok, _} <- ScopeEvidence.repository(worktree.path, base),
                   do: {:ok, worktree}

            run ->
              if run.goal_id == metadata["goal_id"] and
                   run.workspace_ref == worktree.workspace_ref and
                   run.extensions[PlanBinding.key()] == metadata[PlanBinding.key()],
                 do: {:ok, worktree},
                 else: {:error, :sibling_workspace_owner_mismatch}
          end
        else
          {:error, :sibling_workspace_binding_mismatch}
        end

      {:error, :not_found} ->
        with {:ok, _} <- ScopeEvidence.repository(source, base) do
          Worktrees.create(
            source,
            run_id,
            base,
            Keyword.merge(opts, private_git: true, metadata: metadata)
          )
        end

      error ->
        error
    end
  end

  @doc false
  def bound?(worktree, run_id, base, metadata, opts) do
    root = Keyword.get(opts, :worktrees_dir, Shoestring.State.path(:worktrees)) |> Path.expand()

    worktree.run_id == run_id and worktree.metadata == metadata and worktree.base_commit == base and
      Path.expand(worktree.repo_path) == Shoestring.Worktrees.PrivateGit.path(root, run_id) and
      Path.expand(worktree.path) == Path.join(root, "run-#{run_id}") and
      worktree.branch == "shoestring/run-#{run_id}"
  end

  defp record(repo, goal_id, binding, worktree, base, opts) do
    case repo.transaction(
           fn ->
             authority = Plans.authority(goal_id, repo: repo)

             unless authority && authority.revision.digest == binding["plan_digest"] &&
                      authority.revision.revision_number == binding["revision_number"],
                    do: repo.rollback(:plan_authority_changed)

             case Trajectory.append(
                    goal_id,
                    %{
                      "type" => "cobbler.plan.workspace.prepared",
                      "schema_version" => 1,
                      "actor" => "cobbler",
                      "occurred_at" => Keyword.get(opts, :now, DateTime.utc_now()),
                      "idempotency_key" => "plan-sibling-workspace:#{worktree.run_id}",
                      "payload" =>
                        Map.merge(binding, %{
                          "run_id" => worktree.run_id,
                          "accepted_base" => base,
                          "branch" => worktree.branch,
                          "workspace_ref" => worktree.workspace_ref
                        })
                    },
                    writer_opts: [transaction_repo: repo]
                  ) do
               {:ok, event} -> event
               {:error, reason} -> repo.rollback(reason)
             end
           end,
           mode: :immediate
         ) do
      {:ok, event} -> {:ok, event}
      error -> error
    end
  end
end
