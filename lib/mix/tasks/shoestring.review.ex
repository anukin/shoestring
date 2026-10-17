defmodule Mix.Tasks.Shoestring.Review do
  use Mix.Task
  @shortdoc "List cross-reviews and decide the ones that wait for you"
  @moduledoc """
      mix shoestring.review list GOAL
      mix shoestring.review show GOAL TASK
      mix shoestring.review accept GOAL TASK --reason TEXT [--by human:NAME]
      mix shoestring.review reject GOAL TASK --reason TEXT [--by human:NAME]
      mix shoestring.review retry GOAL TASK --reason TEXT [--by human:NAME]

  TASK is a plan task id; the command acts on that task's latest review in
  the goal's current execution. A review decides by itself when it can: it
  approves, or sends the task back for repair with its blocking findings.
  These commands record your decision when it cannot:

  - `accept` takes the reviewed commit without (or despite) the review: a
    waiver when review could not run, or a dismissal of findings that will not
    be repaired automatically. Your reason is recorded with the acceptance.
  - `reject` fails the attempt; the task then needs a plan change.
  - `retry` allows one more review call after a failed or lost one (at most
    two calls per review).

  Capacity confirmations for a held review call are asked by `shoestring
  follow`. The service applies a decision on its next pass; this command
  starts no provider and merges nothing.
  """

  alias Shoestring.CLI.WorkLoop
  alias Shoestring.Cobbler.{ExecutionControl, PlanReview}

  @impl Mix.Task
  def run(args) do
    case OptionParser.parse(args, strict: [reason: :string, by: :string]) do
      {_opts, ["list", goal], []} ->
        with_goal(goal, fn _goal_id, reviews ->
          if reviews == [], do: Mix.shell().info("No reviews.")
          Enum.each(reviews, &list_line/1)
        end)

      {_opts, ["show", goal, task], []} ->
        with_goal(goal, fn _goal_id, reviews -> show(latest!(reviews, task)) end)

      {opts, [decision, goal, task], []} when decision in ["accept", "reject", "retry"] ->
        reason = opts[:reason] || Mix.raise("--reason is required")

        with_goal(goal, fn goal_id, reviews ->
          review = latest!(reviews, task)

          attrs = [
            review_id: review.review_id,
            decision_id: Ecto.UUID.generate(),
            decision: decision,
            reason: reason,
            decided_by: opts[:by] || WorkLoop.default_human()
          ]

          case PlanReview.decide(goal_id, attrs) do
            {:ok, _} ->
              Mix.shell().info(
                "Recorded #{decision} for the review of #{task}; the service applies it next."
              )

            {:error, :review_decision_not_allowed} ->
              Mix.raise(
                "The review of #{task} is #{review.state}; #{decision} is not allowed now."
              )

            {:error, reason} ->
              Mix.raise("Not recorded: #{inspect(reason)}")
          end
        end)

      _ ->
        Mix.raise("Invalid arguments. See mix help shoestring.review")
    end
  end

  defp with_goal(goal, fun) do
    goal_id =
      case Ecto.UUID.cast(goal) do
        {:ok, id} -> id
        :error -> Mix.raise("GOAL must be a goal id; see mix shoestring.goals list")
      end

    Shoestring.CLI.Repository.with_repo(fn _repo ->
      case ExecutionControl.status(goal_id) do
        {:ok, %{reviews: reviews}} -> fun.(goal_id, reviews)
        {:ok, _} -> Mix.raise("The goal has no execution yet.")
        {:error, reason} -> Mix.raise("Status unavailable: #{inspect(reason)}")
      end
    end)
  end

  defp latest!(reviews, task) do
    reviews
    |> Enum.filter(&(&1.plan_task_id == task))
    |> Enum.max_by(& &1.attempt, fn -> Mix.raise("No review of task #{task}.") end)
  end

  defp list_line(review) do
    flag = if review.needs_user?, do: "  <- needs you", else: ""

    Mix.shell().info(
      "#{review.plan_task_id} attempt #{review.attempt} round #{review.round}: #{review.state} " <>
        "(#{review.reviewer || "no reviewer"}#{if review.model, do: ":" <> review.model}" <>
        "#{if review.unavailable, do: ", " <> review.unavailable}) at #{String.slice(review.commit, 0, 12)}#{flag}"
    )
  end

  defp show(review) do
    list_line(review)
    if review.reason, do: Mix.shell().info("  reason: #{review.reason}")

    for finding <- review.findings do
      where = if finding["path"], do: " #{finding["path"]}:#{finding["line"]}", else: ""

      unsupported =
        if finding["reference"] == "unsupported", do: " (path not in the packet)", else: ""

      Mix.shell().info(
        "  #{finding["id"]} #{finding["severity"]}#{where}#{unsupported}: #{finding["claim"]}"
      )

      Mix.shell().info("     fix: #{finding["correction"]}")
    end
  end
end
