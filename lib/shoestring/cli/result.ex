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

  @doc """
  The completed goal's result as data: `:goal_id`, `:commit`, `:base`,
  `:worktree`, `:repository`, `:checks` (the goal gates recorded at
  completion), `:reviews`, `:diff_stat` (lines, or `nil` when `git diff`
  failed) and `:take` (the commands the user runs). Options: `:status` (for
  tests).
  """
  @spec fetch(Ecto.UUID.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch(goal_id, opts \\ []) do
    status_fun = Keyword.get(opts, :status, &ExecutionControl.status/1)

    with {:ok, status} <- status_fun.(goal_id),
         true <- status[:completed?] == true || {:error, :not_completed},
         %TrajectoryEvent{payload: completed} <- completion(goal_id) || {:error, :not_completed},
         %{revision: revision} <- Plans.authority(goal_id) || {:error, :no_approved_plan},
         base = revision.content["goal"]["repository"]["base_revision"],
         commit = completed["commit"],
         {:ok, worktree} <- worktree_with(status, commit) do
      repository = status.execution.repository_path

      diff_stat =
        case System.cmd("git", ["-C", worktree, "diff", "--stat", base, commit]) do
          {stat, 0} -> String.split(stat, "\n", trim: true)
          _ -> nil
        end

      {:ok,
       %{
         goal_id: goal_id,
         commit: commit,
         base: base,
         worktree: worktree,
         repository: repository,
         checks:
           for gate <- get_in(completed, ["evidence", "gates"]) || [] do
             %{
               argv: gate["argv"],
               exit_status: gate["exit_status"],
               required: gate["required"] != false,
               last_line:
                 gate["output"] |> to_string() |> String.split("\n", trim: true) |> List.last()
             }
           end,
         reviews: Enum.map(status[:reviews] || [], &review/1),
         diff_stat: diff_stat,
         take: [
           "cd #{Shoestring.Shell.argument(repository)}",
           "git fetch #{Shoestring.Shell.argument(worktree)} #{Shoestring.Shell.argument(commit)}",
           "git merge FETCH_HEAD"
         ]
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :not_completed}
    end
  end

  @doc "Fetches and prints the result as text on stdout. Options: `:shell`, `:status`."
  @spec show(Ecto.UUID.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def show(goal_id, opts \\ []) do
    with {:ok, result} <- fetch(goal_id, opts) do
      print(result, Keyword.get(opts, :shell, Shoestring.CLI.Shell))
      {:ok, result}
    end
  end

  @doc "Prints a fetched result: data on stdout (`info`), notes on stderr (`error`)."
  def print(result, shell) do
    shell.info("Result: #{result.commit}")
    shell.info("  Built on #{String.slice(result.base, 0, 12)} in #{result.worktree}")

    for check <- result.checks do
      optional = if check.required, do: "", else: " (optional)"
      shell.info("  Check: #{check.argv} -> exit #{check.exit_status}#{optional}")
      if check.last_line, do: shell.info("    #{check.last_line}")
    end

    shell.info("  Every check that ran: shoestring checks #{result.goal_id}")
    reviews(shell, result.reviews)

    case result.diff_stat do
      nil -> shell.error("  (diff unavailable)")
      lines -> Enum.each(lines, &shell.info("  #{&1}"))
    end

    shell.info("")
    shell.info("To take it into your repository:")
    Enum.each(result.take, &shell.info("  #{&1}"))
  end

  @doc "One review round as data: reviewer, state, and its findings."
  def review(review) do
    %{
      plan_task_id: review.plan_task_id,
      attempt: review.attempt,
      reviewer: review.reviewer,
      model: review.model,
      unavailable: review.unavailable,
      state: review.state,
      blocking: Enum.count(review.findings, &Shoestring.Cobbler.Review.Findings.blocking?/1),
      findings: review.findings
    }
  end

  # Every review round, in order: what each found and how it ended, so the
  # repair history and any waived or dismissed findings are visible.
  defp reviews(shell, reviews) do
    for review <- reviews do
      reviewer =
        if review.reviewer, do: "#{review.reviewer}:#{review.model}", else: review.unavailable

      shell.info(
        "  Review: #{review.plan_task_id} attempt #{review.attempt} by #{reviewer} -> " <>
          "#{review.state} (#{review.blocking} blocking, #{length(review.findings)} total)"
      )

      for finding <- review.findings, finding["severity"] == "blocking" do
        shell.info(
          "    #{finding["id"]} #{finding["path"]}:#{finding["line"]} #{finding["claim"]}"
        )
      end
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
