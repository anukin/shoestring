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

        Enum.reduce_while(accepted, {:ok, gate_opts}, fn evidence, acc ->
          case Shoestring.Cobbler.GateProcess.run(
                 ["git", "merge-base", "--is-ancestor", evidence.commit, "HEAD"],
                 path,
                 15_000,
                 1024
               ) do
            {:ok, %{exit_status: 0}} -> {:cont, acc}
            _ -> {:halt, {:error, :accepted_commit_not_integrated}}
          end
        end)
      end
    else
      _ -> {:error, :global_plan_worktree_missing}
    end
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
        {:ok, Keyword.put(gate_opts, :worktree_path, worktree.path)}
      end
    end
  end

  defp attempt_worktree(run, opts) do
    case Worktrees.get(run.id) do
      {:ok, worktree} ->
        {:ok, worktree}

      {:error, _} ->
        with {:ok, chains} <-
               Shoestring.Cobbler.PlanRunLineage.load(
                 Keyword.get(opts, :repo, Shoestring.Repo),
                 run.goal_id
               ),
             {root, _ids} <- Enum.find(chains, fn {_root, ids} -> run.id in ids end) do
          Worktrees.get(root)
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
