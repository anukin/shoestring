defmodule Shoestring.Cobbler.PlanWorkspace do
  @moduledoc false
  alias Shoestring.Cobbler.PlanBinding
  alias Shoestring.Harness.RunRecord
  alias Shoestring.Worktrees

  def global_gate_opts(repo, accepted, opts) do
    with %{run_id: run_id} <- List.last(accepted),
         %RunRecord{} = run <- repo.get(RunRecord, run_id),
         {:ok, gate_opts} <- resolve_gate_opts(run, opts) do
      if is_function(Keyword.get(gate_opts, :runner), 3) do
        {:ok, gate_opts}
      else
        path = Keyword.fetch!(gate_opts, :worktree_path)

        with :ok <- require_integrated(path, accepted), do: {:ok, gate_opts}
      end
    else
      _ -> {:error, :global_plan_worktree_missing}
    end
  end

  @doc false
  # Global verification after human integration: a private store copied from
  # the source repository at the approved base, reused for the same execution.
  # Every accepted commit must be an ancestor of that base (a merge preserves
  # this; a cherry-pick does not). The user's source checkout is only read.
  def integration_gate_opts(_repo, execution, base, accepted, opts) do
    gate_opts = Keyword.get(opts, :gate_runner_opts, [])

    if is_function(Keyword.get(gate_opts, :runner), 3) do
      {:ok, gate_opts}
    else
      source = execution[:repository_path] || Keyword.get(opts, :repository_path)
      id = Shoestring.Cobbler.PlanExecutor.integration_workspace_id(execution.execution_id, base)

      metadata = %{
        "shoestring.plan:integration" => %{
          "execution_id" => execution.execution_id,
          "revision_number" => execution.revision_number,
          "plan_digest" => execution.plan_digest,
          "base" => base
        }
      }

      with true <- is_binary(source) || {:error, :global_plan_worktree_missing},
           {:ok, worktree} <- integration_worktree(source, id, base, metadata, opts),
           :ok <- require_integrated(worktree.path, accepted, base) do
        {:ok, put_paths(gate_opts, worktree.path, opts)}
      end
    end
  end

  # The gate sandbox derives its roots from the same worktree registry.
  defp put_paths(gate_opts, path, opts) do
    gate_opts
    |> Keyword.put(:worktree_path, path)
    |> Keyword.put_new(:worktrees_dir, Keyword.get(opts, :worktrees_dir))
  end

  defp integration_worktree(source, id, base, metadata, opts) do
    storage = Keyword.take(opts, [:worktrees_dir])

    case Worktrees.get(id, storage) do
      {:ok, worktree} ->
        if worktree.base_commit == base and worktree.metadata == metadata,
          do: {:ok, worktree},
          else: {:error, :integration_worktree_mismatch}

      {:error, _} ->
        case Worktrees.create(
               source,
               id,
               base,
               Keyword.merge(storage, private_git: true, metadata: metadata)
             ) do
          {:ok, worktree} -> {:ok, worktree}
          {:error, _} -> {:error, :accepted_commit_not_integrated}
        end
    end
  end

  def require_integrated(path, accepted, revision \\ "HEAD") do
    Enum.reduce_while(accepted, :ok, fn evidence, :ok ->
      case Shoestring.Cobbler.GateProcess.run(
             ["git", "merge-base", "--is-ancestor", evidence.commit, revision],
             path,
             15_000,
             1024
           ) do
        {:ok, %{exit_status: 0}} -> {:cont, :ok}
        _ -> {:halt, {:error, :accepted_commit_not_integrated}}
      end
    end)
  end

  def gate_opts(repo, context, opts) do
    case repo.get_by(RunRecord, id: context.run_id, goal_id: context.goal_id) do
      %RunRecord{} = run ->
        expected = %{
          "revision_number" => context.revision_number,
          "plan_digest" => context.plan_digest,
          "plan_task_id" => context.plan_task_id,
          "attempt" => context.attempt
        }

        binding = (run.extensions || %{})[PlanBinding.key()] || %{}

        if Map.take(binding, Map.keys(expected)) == expected do
          resolve_gate_opts(run, opts)
        else
          {:error, :run_plan_binding_mismatch}
        end

      _ ->
        {:error, :plan_run_not_found}
    end
  end

  def resolve_gate_opts(run, opts) do
    gate_opts = Keyword.get(opts, :gate_runner_opts, [])

    if is_function(Keyword.get(gate_opts, :runner), 3) do
      {:ok, gate_opts}
    else
      with {:ok, worktree} <- attempt_worktree(run, opts),
           true <-
             worktree.workspace_ref == run.workspace_ref || {:error, :plan_worktree_mismatch},
           :ok <- same_directory(gate_opts, worktree.path) do
        {:ok, put_paths(gate_opts, worktree.path, opts)}
      end
    end
  end

  defp attempt_worktree(run, opts) do
    case Worktrees.get(run.id, opts) do
      {:ok, worktree} ->
        {:ok, worktree}

      {:error, _} ->
        with {:ok, chains} <-
               Shoestring.Cobbler.PlanRunLineage.load(
                 Keyword.get(opts, :repo, Shoestring.Repo),
                 run.goal_id
               ),
             {root, _ids} <- Enum.find(chains, fn {_root, ids} -> run.id in ids end) do
          Worktrees.get(root, opts)
        else
          _ -> {:error, :plan_attempt_worktree_missing}
        end
    end
  end

  defp same_directory(opts, actual) do
    case Keyword.get(opts, :worktree_path) do
      nil ->
        :ok

      supplied ->
        if Path.expand(supplied) == Path.expand(actual),
          do: :ok,
          else: {:error, :plan_worktree_mismatch}
    end
  end
end
