defmodule Shoestring.Cobbler.PlanMerge do
  @moduledoc """
  Shoestring's own integration of a fan-out execution's accepted commits
  (iteration 16 C3).

  Once every fan-out task whose result is needed is accepted, the accepted
  commits are merged one after another, in plan order, onto the approved base
  in a worktree Shoestring owns (private Git storage, never the person's
  repository). The merged commit is recorded as the execution's integration
  (`Shoestring.Cobbler.PlanIntegration.record_merge/3`), so the global gates
  rerun at it and the person takes one commit.

  A conflict is never resolved: the merge is aborted, recorded with the task
  and the conflicting files (`cobbler.plan.merge.blocked`), and the execution
  waits for the person, who may merge the commits themselves and record that
  integration as before. A failure to merge is recorded the same way. Git
  runs with hooks disabled and without signing; nothing reads or changes the
  person's checkout except fetching the base from it.
  """

  import Ecto.Query

  alias Shoestring.Cobbler.{GateProcess, PlanExecutor, PlanIntegration, Plans, PlanRunLineage}
  alias Shoestring.{Repo, Trajectory, Worktrees}
  alias Shoestring.Trajectory.TrajectoryEvent

  @blocked "cobbler.plan.merge.blocked"
  @git_ms 120_000
  @max_files 50

  @doc """
  Merges and records. `{:ok, :integrated}` once recorded (or already),
  `{:blocked, payload}` on a conflict or failure (recorded), `{:error,
  reason}` when there is nothing Shoestring may merge.
  """
  def integrate(goal_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, status} <- PlanExecutor.status(goal_id, opts),
         %{execution: execution, completed?: false, cancelled?: false} <- status,
         true <- status.dispatch_mode == :fanout_v1 || {:error, :not_fanout},
         true <- is_nil(status.integration) || :integrated,
         %{revision: revision} <- Plans.authority(goal_id, repo: repo),
         true <- revision.digest == execution.plan_digest || {:error, :plan_changed},
         [_ | _] = accepted <- in_plan_order(status.accepted_evidence, revision) do
      commits = accepted |> Enum.map(& &1.commit) |> Enum.uniq() |> Enum.sort()
      base = get_in(revision.content, ["goal", "repository", "base_revision"])

      source =
        execution[:base_source] || execution[:repository_path] ||
          Keyword.get(opts, :repository_path)

      # From here every stop is recorded, so the execution shows it waits for
      # the person rather than looking busy.
      case source && merge(goal_id, execution, base, source, accepted, revision, opts) do
        nil ->
          block(goal_id, execution, commits, failed(:no_source), opts)

        {:ok, path, commit} ->
          case PlanIntegration.record_merge(
                 goal_id,
                 %{
                   execution_id: execution.execution_id,
                   commit: commit,
                   source: path,
                   merged_task_ids: Enum.map(accepted, & &1.plan_task_id)
                 },
                 Keyword.take(opts, [:repo])
               ) do
            {:ok, _event} -> {:ok, :integrated}
            {:error, reason} -> block(goal_id, execution, commits, failed(reason), opts)
          end

        {:conflict, detail} ->
          block(goal_id, execution, commits, Map.put(detail, "reason", "conflict"), opts)

        {:error, reason} ->
          block(goal_id, execution, commits, failed(reason), opts)
      end
    else
      :integrated -> {:ok, :integrated}
      [] -> {:error, :nothing_accepted}
      {:error, _} = error -> error
      _ -> {:error, :not_integrable}
    end
  end

  @doc """
  The recorded block of the execution's current accepted commits, if its
  merge stopped, else nil. A block for other commits (a task accepted since)
  no longer applies.
  """
  def blocked(goal_id, status) do
    with %{execution: %{execution_id: execution_id}} <- status,
         nil <- status[:integration] do
      commits =
        (status[:accepted_evidence] || []) |> Enum.map(& &1.commit) |> Enum.uniq() |> Enum.sort()

      Repo.one(
        from event in TrajectoryEvent,
          where:
            event.goal_id == ^goal_id and event.type == @blocked and
              event.idempotency_key == ^key(execution_id, commits),
          select: event.payload
      )
    else
      _ -> nil
    end
  end

  defp failed(reason),
    do: %{"reason" => "failed", "detail" => String.slice(inspect(reason), 0, 500)}

  defp block(goal_id, execution, commits, detail, _opts) do
    payload =
      Map.merge(detail, %{
        "execution_id" => execution.execution_id,
        "revision_number" => execution.revision_number,
        "plan_digest" => execution.plan_digest,
        "accepted_commits" => commits
      })

    case Trajectory.append(goal_id, %{
           "type" => @blocked,
           "schema_version" => 1,
           "actor" => "cobbler",
           "occurred_at" => DateTime.utc_now(),
           "idempotency_key" => key(execution.execution_id, commits),
           "payload" => payload
         }) do
      {:ok, _} -> {:blocked, payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp key(execution_id, commits),
    do:
      "plan-merge-blocked:#{execution_id}:" <>
        Base.encode16(:crypto.hash(:sha256, Enum.join(commits, ",")), case: :lower)

  # The latest accepted evidence of each task, in the plan's task order.
  defp in_plan_order(evidence, revision) do
    by_task = Map.new(evidence, &{&1.plan_task_id, &1})

    for %{"id" => id} <- revision.content["tasks"], Map.has_key?(by_task, id), do: by_task[id]
  end

  defp merge(goal_id, execution, base, source, accepted, revision, opts) do
    with {:ok, worktree} <- worktree(execution, base, source, opts),
         :ok <- clear_unfinished(worktree.path),
         :ok <- identity(worktree.path),
         :ok <- merge_each(goal_id, worktree.path, accepted, revision, opts) do
      case git(worktree.path, ["rev-parse", "HEAD"]) do
        {:ok, head} -> {:ok, worktree.path, head}
        _ -> {:error, :merge_head_unreadable}
      end
    end
  end

  # One merge worktree per execution and base, reused after a restart.
  defp worktree(execution, base, source, opts) do
    id = PlanExecutor.merge_workspace_id(execution.execution_id, base)
    storage = Keyword.take(opts, [:worktrees_dir])

    metadata = %{
      "shoestring.plan:merge" => %{
        "execution_id" => execution.execution_id,
        "plan_digest" => execution.plan_digest,
        "base" => base
      }
    }

    case Worktrees.get(id, storage) do
      {:ok, worktree} ->
        if worktree.base_commit == base and worktree.metadata == metadata,
          do: {:ok, worktree},
          else: {:error, :merge_worktree_mismatch}

      {:error, _} ->
        Worktrees.create(
          source,
          id,
          base,
          Keyword.merge(storage, private_git: true, metadata: metadata)
        )
    end
  end

  # A merge interrupted by a restart is aborted and redone.
  defp clear_unfinished(path) do
    case git(path, ["rev-parse", "-q", "--verify", "MERGE_HEAD"]) do
      {:ok, _} ->
        case git(path, ["merge", "--abort"]) do
          {:ok, _} -> :ok
          _ -> {:error, :merge_abort_failed}
        end

      _ ->
        :ok
    end
  end

  defp identity(path) do
    case git(path, ["config", "user.email"]) do
      {:ok, _} ->
        :ok

      _ ->
        with {:ok, _} <- git(path, ["config", "user.name", "Shoestring"]),
             {:ok, _} <- git(path, ["config", "user.email", "shoestring@localhost"]) do
          :ok
        else
          _ -> {:error, :merge_identity_failed}
        end
    end
  end

  defp merge_each(goal_id, path, accepted, revision, opts) do
    titles = Map.new(revision.content["tasks"], &{&1["id"], &1["title"]})

    Enum.reduce_while(accepted, {:ok, []}, fn evidence, {:ok, merged} ->
      case merge_one(goal_id, path, evidence, titles[evidence.plan_task_id], merged, opts) do
        :ok -> {:cont, {:ok, merged ++ [evidence.plan_task_id]}}
        other -> {:halt, other}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      other -> other
    end
  end

  defp merge_one(goal_id, path, evidence, title, merged, opts) do
    if ancestor?(path, evidence.commit) do
      :ok
    else
      with {:ok, from} <- evidence_worktree(goal_id, evidence, opts),
           {:ok, _} <- git(path, ["fetch", "--no-tags", "--", from, evidence.commit]) do
        message = "Merge #{evidence.plan_task_id}: #{title || evidence.plan_task_id}"

        case git(path, ["merge", "--no-ff", "--no-edit", "-m", message, evidence.commit]) do
          {:ok, _} ->
            :ok

          {:failed, output} ->
            files =
              case git(path, ["diff", "--name-only", "--diff-filter=U"]) do
                {:ok, out} -> out |> String.split("\n", trim: true) |> Enum.take(@max_files)
                _ -> []
              end

            _ = git(path, ["merge", "--abort"])

            if files == [],
              do: {:error, {:merge_failed, String.slice(output, 0, 300)}},
              else:
                {:conflict,
                 %{
                   "plan_task_id" => evidence.plan_task_id,
                   "files" => files,
                   "merged_task_ids" => merged
                 }}

          error ->
            error
        end
      else
        {:failed, _} -> {:error, :merge_fetch_failed}
        error -> error
      end
    end
  end

  defp ancestor?(path, commit),
    do: match?({:ok, _}, git(path, ["merge-base", "--is-ancestor", commit, "HEAD"]))

  # The accepted run's private worktree (a continued attempt keeps its
  # lineage root's).
  defp evidence_worktree(goal_id, evidence, opts) do
    storage = Keyword.take(opts, [:worktrees_dir])

    case Worktrees.get(evidence.run_id, storage) do
      {:ok, %{path: path}} ->
        {:ok, path}

      _ ->
        with {:ok, chains} <-
               PlanRunLineage.load(Keyword.get(opts, :repo, Repo), goal_id),
             {root, _} <- Enum.find(chains, fn {_root, ids} -> evidence.run_id in ids end),
             {:ok, %{path: path}} <- Worktrees.get(root, storage) do
          {:ok, path}
        else
          _ -> {:error, :accepted_worktree_missing}
        end
    end
  end

  defp git(path, args) do
    argv =
      ["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"] ++ args

    case GateProcess.run(argv, path, @git_ms, 1_048_576) do
      {:ok, %{exit_status: 0, output: output}} -> {:ok, String.trim(output)}
      {:ok, %{output: output}} -> {:failed, output}
      {:error, reason} -> {:error, {:git, reason}}
    end
  end
end
