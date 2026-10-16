defmodule Shoestring.CLI.Result do
  @moduledoc """
  `shoestring result GOAL`: the verified result of a completed goal and the
  exact commands to take it into the user's repository.

  Shoestring never modifies the user's checkout (locked decision). The work
  lives in the private worktree of the run that produced the final commit;
  this prints the `git fetch`/`git merge` the user runs themselves, the goal
  gate output recorded at completion, and a diff stat against the approved
  base (read-only `git diff`).
  """

  import Ecto.Query

  alias Shoestring.{Repo, Worktrees}
  alias Shoestring.Cobbler.{ExecutionControl, Plans}
  alias Shoestring.Trajectory.TrajectoryEvent

  @doc "Prints the result. Options: `:shell`, `:status` (for tests)."
  @spec show(Ecto.UUID.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def show(goal_id, opts \\ []) do
    shell = Keyword.get(opts, :shell, Mix.shell())
    status_fun = Keyword.get(opts, :status, &ExecutionControl.status/1)

    with {:ok, status} <- status_fun.(goal_id),
         true <- status[:completed?] == true || {:error, :not_completed},
         %TrajectoryEvent{payload: completed} <- completion(goal_id) || {:error, :not_completed},
         %{revision: revision} <- Plans.authority(goal_id) || {:error, :no_approved_plan},
         base = revision.content["goal"]["repository"]["base_revision"],
         commit = completed["commit"],
         {:ok, worktree} <- worktree_with(status, commit) do
      repository = status.execution.repository_path

      shell.info("Result: #{commit}")
      shell.info("  Built on #{String.slice(base, 0, 12)} in #{worktree}")

      for gate <- get_in(completed, ["evidence", "gates"]) || [] do
        shell.info("  Check: #{gate["argv"]} -> exit #{gate["exit_status"]}")
        last = gate["output"] |> to_string() |> String.split("\n", trim: true) |> List.last()
        if last, do: shell.info("    #{last}")
      end

      case System.cmd("git", ["-C", worktree, "diff", "--stat", base, commit]) do
        {stat, 0} -> Enum.each(String.split(stat, "\n", trim: true), &shell.info("  #{&1}"))
        _ -> shell.info("  (diff unavailable)")
      end

      shell.info("")
      shell.info("To take it into your repository:")
      shell.info("  cd #{repository}")
      shell.info("  git fetch #{worktree} #{commit}")
      shell.info("  git merge FETCH_HEAD")

      {:ok, %{commit: commit, base: base, worktree: worktree, repository: repository}}
    else
      {:error, _} = error -> error
      _ -> {:error, :not_completed}
    end
  end

  defp completion(goal_id) do
    Repo.one(
      from e in TrajectoryEvent,
        where: e.goal_id == ^goal_id and e.type == "cobbler.plan.execution.completed",
        order_by: [desc: e.sequence],
        limit: 1
    )
  end

  # The accepted run whose private worktree contains the final commit.
  defp worktree_with(status, commit) do
    status
    |> Map.get(:accepted_evidence, [])
    |> Enum.sort_by(&(&1.commit != commit))
    |> Enum.find_value({:error, :result_worktree_not_found}, fn evidence ->
      with {:ok, %{path: path}} <- Worktrees.get(evidence.run_id),
           {_, 0} <-
             System.cmd("git", ["-C", path, "cat-file", "-e", commit <> "^{commit}"],
               stderr_to_stdout: true
             ) do
        {:ok, path}
      else
        _ -> nil
      end
    end)
  end
end
