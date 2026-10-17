defmodule Shoestring.CLI.Follow do
  @moduledoc """
  `shoestring follow GOAL`: prints a goal's progress from durable history and
  asks the human when the work waits for them. It reads the local database on
  a bounded interval; waiting costs no inference.

  It never starts, stops, replaces or cancels work. Interrupting it leaves the
  work running, and a later `follow` prints the history again from the start,
  so nothing is lost or duplicated in the record.

  The only decisions it records are capacity confirmations: for the one held
  task attempt (iteration 7A locked decision) and for the one held
  cross-review call (iteration 8), each after the human answers `y`.
  Everything else that needs a human is described with the command to run.
  """

  import Ecto.Query

  alias Shoestring.Cobbler.{ExecutionControl, PlanReview, Plans}
  alias Shoestring.Repo
  alias Shoestring.Trajectory.TrajectoryEvent

  @interval_ms 1_000

  @type outcome :: :completed | :cancelled | :needs_user | :held | :stopped

  @doc """
  Follows `goal_id` until it completes, is cancelled, needs a human decision it
  cannot take here, or is left held. Options: `:shell`, `:by`, `:interval_ms`,
  `:from_execution` (start at the latest execution request; `do` uses it), and
  for tests `:status`, `:events`, `:confirm`, `:sleep`, `:max_polls`.
  """
  @spec run(Ecto.UUID.t(), keyword()) :: {:ok, outcome()} | {:error, term()}
  def run(goal_id, opts \\ []) do
    state = %{
      goal_id: goal_id,
      shell: Keyword.get(opts, :shell, Mix.shell()),
      by: Keyword.fetch!(opts, :by),
      status: Keyword.get(opts, :status, &ExecutionControl.status/1),
      events: Keyword.get(opts, :events, &events_after/2),
      confirm: Keyword.get(opts, :confirm, &ExecutionControl.confirm_capacity/2),
      confirm_review: Keyword.get(opts, :confirm_review, &PlanReview.confirm/2),
      sleep:
        Keyword.get(opts, :sleep, fn ->
          Process.sleep(Keyword.get(opts, :interval_ms, @interval_ms))
        end),
      polls_left: Keyword.get(opts, :max_polls, :infinity),
      cursor:
        if(Keyword.get(opts, :from_execution, false), do: execution_cursor(goal_id), else: 0),
      asked: MapSet.new()
    }

    poll(state)
  end

  defp poll(%{polls_left: 0}), do: {:ok, :stopped}

  defp poll(state) do
    events = state.events.(state.goal_id, state.cursor)
    Enum.each(events, &describe(state.shell, &1))
    state = %{state | cursor: Enum.reduce(events, state.cursor, &max(&1.sequence, &2))}

    case state.status.(state.goal_id) do
      {:ok, %{completed?: true}} ->
        state.shell.info("Done.")
        {:ok, :completed}

      {:ok, %{cancelled?: true}} ->
        state.shell.info("The goal was cancelled.")
        {:ok, :cancelled}

      {:ok, %{needs_user?: true} = status} ->
        needs_user(state, status)
        {:ok, :needs_user}

      {:ok, %{} = status} ->
        case {held_review(status), held(state.goal_id, status)} do
          {%{} = review, _} ->
            key = {review.review_id, review.calls}

            if MapSet.member?(state.asked, key),
              do: wait(state),
              else: confirm_review(%{state | asked: MapSet.put(state.asked, key)}, review)

          {nil, held} ->
            held_task(state, status, held)
        end

      {:error, _} = error ->
        error
    end
  end

  defp held_task(state, status, held) do
    case held do
      {decision_id, task_id, attempt} ->
        if MapSet.member?(state.asked, decision_id),
          do: wait(state),
          else:
            confirm(
              %{state | asked: MapSet.put(state.asked, decision_id)},
              status,
              task_id,
              attempt
            )

      nil ->
        wait(state)
    end
  end

  # A review call held for capacity, while its task waits for it.
  defp held_review(status) do
    Enum.find(status[:reviews] || [], &(&1.state == "held"))
  end

  defp confirm_review(state, review) do
    state.shell.info(
      "The review of task #{review.plan_task_id} (attempt #{review.attempt}) by " <>
        "#{review.reviewer}:#{review.model} is held: #{review.reason}"
    )

    answer =
      "Confirm capacity for this one review call? [y/N] "
      |> state.shell.prompt()
      |> String.trim()
      |> String.downcase()

    if answer in ["y", "yes"] do
      attrs = %{
        review_id: review.review_id,
        confirmation_id: Ecto.UUID.generate(),
        confirmed_by: state.by
      }

      case state.confirm_review.(state.goal_id, attrs) do
        {:ok, _} ->
          state.shell.info("Confirmed. The service makes the call on its next pass.")
          wait(state)

        {:error, reason} ->
          state.shell.info("Not confirmed (#{inspect(reason)}); the review stays held.")
          wait(state)
      end
    else
      state.shell.info(
        "Left held. Run `shoestring follow #{state.goal_id}` to be asked again; " <>
          "the work stays queued."
      )

      {:ok, :held}
    end
  end

  defp wait(state) do
    state.sleep.()
    polls = if state.polls_left == :infinity, do: :infinity, else: state.polls_left - 1
    poll(%{state | polls_left: polls})
  end

  # A held admission for the next task, while nothing runs.
  defp held(goal_id, %{last_admission: %{"result" => "require_confirmation"} = decision} = status) do
    if is_nil(status[:active_run_id]) do
      case next_task(goal_id, status) do
        {task_id, attempt} -> {decision["decision_id"], task_id, attempt}
        nil -> nil
      end
    end
  end

  defp held(_goal_id, _status), do: nil

  defp next_task(goal_id, %{execution: execution} = status) do
    with %{revision: revision} <- Plans.authority(goal_id),
         true <- revision.revision_number == execution.revision_number do
      Enum.find_value(revision.content["tasks"], fn task ->
        ready? =
          task["id"] not in status.accepted and
            Enum.all?(task["depends_on"], &(&1 in status.accepted))

        if ready?, do: {task["id"], Map.get(status.attempts, task["id"], 0) + 1}
      end)
    else
      _ -> nil
    end
  end

  defp confirm(state, status, task_id, attempt) do
    decision = status.last_admission
    state.shell.info("Task #{task_id} is held: #{decision["explanation"]}")

    answer =
      "Confirm capacity for this one attempt of #{task_id}? [y/N] "
      |> state.shell.prompt()
      |> String.trim()
      |> String.downcase()

    if answer in ["y", "yes"] do
      attrs = %{
        execution_id: status.execution.execution_id,
        task_id: task_id,
        attempt: attempt,
        scope: Application.get_env(:shoestring, :run_submission_scope, "subscription"),
        command_id: Ecto.UUID.generate(),
        requested_by: state.by
      }

      case state.confirm.(state.goal_id, attrs) do
        {:ok, _} ->
          state.shell.info("Confirmed. The service admits it on its next pass.")
          wait(state)

        {:error, reason} ->
          state.shell.info("Not confirmed (#{inspect(reason)}); the task stays held.")
          wait(state)
      end
    else
      state.shell.info(
        "Left held. Run `shoestring follow #{state.goal_id}` to be asked again; " <>
          "the work stays queued."
      )

      {:ok, :held}
    end
  end

  defp needs_user(state, status) do
    state.shell.info("The work needs you:")

    if failure = status[:global_failure],
      do: state.shell.info("  The execution failed: #{inspect(failure, limit: 8)}")

    for review <- status[:reviews] || [], review.needs_user? do
      task = review.plan_task_id

      state.shell.info(
        "  The review of task #{task} (attempt #{review.attempt}) #{review_problem(review)}. " <>
          "Decide with `shoestring review accept|reject#{if review.state == "failed" and review.calls < 2, do: "|retry"} " <>
          "#{state.goal_id} #{task} --reason \"...\"`."
      )
    end

    for blocker <- status[:scope_blockers] || [] do
      state.shell.info(
        "  Scope blocker on #{blocker["plan_task_id"] || inspect(blocker, limit: 6)}"
      )
    end

    state.shell.info(
      "  See `mix shoestring.execution status #{state.goal_id}`; resolve with " <>
        "`resolve-scope`, `replan` or `cancel` as docs/cli-execution.md describes."
    )
  end

  defp review_problem(%{state: "escalated", reason: reason}),
    do: "still has blocking findings that will not be repaired automatically (#{reason})"

  defp review_problem(%{state: "failed", reason: reason}), do: "failed (#{reason})"
  defp review_problem(%{unavailable: reason}) when is_binary(reason), do: "cannot run: #{reason}"
  defp review_problem(_review), do: "used every allowed call"

  # -- Events --------------------------------------------------------------

  # Just before the latest execution request, so `do` does not repeat the
  # planning it has already shown.
  defp execution_cursor(goal_id) do
    Repo.one(
      from e in TrajectoryEvent,
        where: e.goal_id == ^goal_id and e.type == "cobbler.plan.execution.requested",
        select: max(e.sequence)
    )
    |> case do
      nil -> 0
      sequence -> sequence - 1
    end
  end

  @doc false
  def events_after(goal_id, sequence) do
    Repo.all(
      from e in TrajectoryEvent,
        where: e.goal_id == ^goal_id and e.sequence > ^sequence,
        order_by: [asc: e.sequence],
        limit: 500
    )
  end

  @doc false
  # One line per event a human follows; other events are not printed.
  def line(%{type: type, payload: p}) do
    task = p["plan_task_id"]

    case type do
      "cobbler.plan.execution.requested" ->
        "Execution requested."

      "cobbler.plan.task.dispatched" ->
        "Task #{task}: started (attempt #{p["attempt"]})."

      "admission.decided" ->
        if p["result"] != "admit", do: "Waiting: #{p["explanation"]}"

      "cobbler.plan.capacity.confirmed" ->
        "Task #{task}: capacity confirmed by #{p["confirmed_by"]}."

      "run.completed" ->
        "  The worker finished; checking its work."

      "run.failed" ->
        "  The worker failed (#{p["error_category"]}: #{p["error_code"]})."

      "run.cancelled" ->
        "  The worker was cancelled."

      "cobbler.plan.task.accepted" ->
        "Task #{task}: accepted at #{short(p["commit"])}."

      "cobbler.plan.task.gate_failed" ->
        case Regex.run(~r/\A\{:gate_unavailable, %\{reason: :(\w+)\}\}\z/, p["reason"] || "") do
          [_, "project_gate_not_configured"] ->
            "Task #{task}: check #{p["gate"]} is not configured; needs your decision."

          [_, reason] ->
            "Task #{task}: checks could not run in a sandbox (#{p["gate"]}: #{reason}); needs your decision."

          nil ->
            "Task #{task}: checks failed (#{p["gate"]})." <> not_run(p["skipped"])
        end

      "cobbler.plan.gate.started" ->
        "  Running check #{p["gate"]}#{optional(p)}."

      "cobbler.plan.gate.completed" ->
        "  Check #{p["gate"]}#{optional(p)}: #{gate_result(p)}."

      "cobbler.plan.task.review_requested" ->
        "Task #{task}: checks passed; cross-review requested (round #{p["round"]})."

      "cobbler.plan.task.reviewed" ->
        case p["outcome"] do
          "approved" ->
            "Task #{task}: review approved (#{p["reviewer"]})."

          "changes_requested" ->
            "Task #{task}: review found #{p["blocking_count"]} blocking finding(s) (#{p["reviewer"]})."

          _ ->
            "Task #{task}: the review call failed (#{p["error_code"]})."
        end

      "cobbler.plan.task.review_blocked" ->
        if p["retry_state"] == "retry",
          do: "Task #{task}: sent back for repair: #{p["reason"]}",
          else: "Task #{task}: review blocked: #{p["reason"]}; needs your decision."

      "cobbler.plan.review.decided" ->
        "Review of task #{task}: #{p["decision"]} by #{p["decided_by"]}."

      "cobbler.plan.task.scope_blocked" ->
        "Task #{task}: changed files outside its scope; needs your decision."

      "cobbler.plan.execution.completed" ->
        "All checks passed at #{short(p["commit"])}."

      "cobbler.plan.cancellation.requested" ->
        "Cancellation requested: #{p["reason"]}"

      _ ->
        nil
    end
  end

  defp describe(shell, event) do
    case line(event) do
      nil -> :ok
      text -> shell.info(text)
    end
  end

  defp not_run(skipped) when is_list(skipped) and skipped != [],
    do: " Not run: #{Enum.join(skipped, ", ")}."

  defp not_run(_skipped), do: ""

  defp optional(%{"required" => false}), do: " (optional)"
  defp optional(_payload), do: ""

  defp gate_result(p) do
    seconds = :erlang.float_to_binary((p["duration_ms"] || 0) / 1000, decimals: 1)

    case p["result"] do
      "passed" -> "passed in #{seconds} s"
      "failed" -> "failed with exit #{p["exit_status"]} in #{seconds} s"
      "timeout" -> "timed out after #{seconds} s"
      "output_oversized" -> "stopped: output over the limit"
      "unavailable" -> "could not run"
      _ -> "not verified"
    end
  end

  defp short(nil), do: "?"
  defp short(sha), do: String.slice(sha, 0, 12)
end
