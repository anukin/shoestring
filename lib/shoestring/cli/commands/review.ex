defmodule Shoestring.CLI.Commands.Review do
  @moduledoc "`shoestring review`: list cross-reviews and decide the ones that wait for you."

  alias Shoestring.CLI.{Command, Refusal, WorkLoop}
  alias Shoestring.Cobbler.{ExecutionControl, PlanReview}

  @help """
  shoestring review list GOAL [--json]
  shoestring review show GOAL TASK [--json]
  shoestring review accept GOAL TASK --reason TEXT [--by human:NAME] [--json]
  shoestring review reject GOAL TASK --reason TEXT [--by human:NAME] [--json]
  shoestring review retry GOAL TASK --reason TEXT [--by human:NAME] [--json]

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
  starts no provider and merges nothing. `--json` prints one JSON object (see
  docs/cli-output.md).
  """

  def help, do: @help

  def run(args, context) do
    case OptionParser.parse(args, strict: [reason: :string, by: :string, json: :boolean]) do
      {opts, ["list", goal], []} ->
        with_goal(goal, context, fn goal_id, reviews ->
          if opts[:json] do
            Command.json(context, %{goal_id: goal_id, reviews: Enum.map(reviews, &data/1)})
          else
            if reviews == [], do: context.shell.error("No reviews.")
            Enum.each(reviews, &context.shell.info(list_line(&1)))
          end
        end)

      {opts, ["show", goal, task], []} ->
        with_goal(goal, context, fn goal_id, reviews ->
          review = latest!(reviews, task)

          if opts[:json],
            do: Command.json(context, %{goal_id: goal_id, review: data(review)}),
            else: show(context.shell, review)
        end)

      {opts, [decision, goal, task], []} when decision in ["accept", "reject", "retry"] ->
        reason = opts[:reason] || Refusal.refuse!("--reason is required", exit_status: 2)

        with_goal(goal, context, fn goal_id, reviews ->
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
              context.shell.error(
                "Recorded #{decision} for the review of #{task}; the service applies it next."
              )

              if opts[:json],
                do:
                  Command.json(context, %{
                    goal_id: goal_id,
                    plan_task_id: task,
                    review_id: review.review_id,
                    decision: decision,
                    state: "recorded"
                  })

            {:error, :review_decision_not_allowed} ->
              Refusal.refuse!(
                "The review of #{task} is #{review.state}; #{decision} is not allowed now."
              )

            {:error, reason} ->
              Refusal.refuse!("Not recorded: #{inspect(reason)}")
          end
        end)

      _ ->
        Refusal.usage!("review")
    end

    :ok
  end

  defp with_goal(goal, context, fun) do
    goal_id = Command.goal_id!(goal)

    context.with_repo.(fn _repo ->
      case ExecutionControl.status(goal_id) do
        {:ok, %{reviews: reviews}} -> fun.(goal_id, reviews)
        {:ok, _} -> Refusal.refuse!("The goal has no execution yet.")
        {:error, reason} -> Refusal.refuse!("Status unavailable: #{inspect(reason)}")
      end
    end)
  end

  defp latest!(reviews, task) do
    reviews
    |> Enum.filter(&(&1.plan_task_id == task))
    |> Enum.max_by(& &1.attempt, fn -> Refusal.refuse!("No review of task #{task}.") end)
  end

  defp data(review) do
    %{
      review_id: review.review_id,
      plan_task_id: review.plan_task_id,
      attempt: review.attempt,
      round: review.round,
      state: review.state,
      reviewer: review.reviewer,
      model: review.model,
      unavailable: review.unavailable,
      commit: review.commit,
      calls: review.calls,
      needs_user: review.needs_user?,
      reason: review.reason,
      findings: review.findings
    }
  end

  defp list_line(review) do
    flag = if review.needs_user?, do: "  <- needs you", else: ""

    "#{review.plan_task_id} attempt #{review.attempt} round #{review.round}: #{review.state} " <>
      "(#{review.reviewer || "no reviewer"}#{if review.model, do: ":" <> review.model}" <>
      "#{if review.unavailable, do: ", " <> review.unavailable}) at #{String.slice(review.commit, 0, 12)}#{flag}"
  end

  defp show(shell, review) do
    shell.info(list_line(review))
    if review.reason, do: shell.info("  reason: #{review.reason}")

    for finding <- review.findings do
      where = if finding["path"], do: " #{finding["path"]}:#{finding["line"]}", else: ""

      unsupported =
        if finding["reference"] == "unsupported", do: " (path not in the packet)", else: ""

      shell.info(
        "  #{finding["id"]} #{finding["severity"]}#{where}#{unsupported}: #{finding["claim"]}"
      )

      shell.info("     fix: #{finding["correction"]}")
    end
  end
end
