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

  All of its output is progress, so it goes to stderr (`error/1`); the
  command prints the result.
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
      shell: Keyword.get(opts, :shell, Shoestring.CLI.Shell),
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
        state.shell.error("Done.")
        {:ok, :completed}

      {:ok, %{cancelled?: true}} ->
        state.shell.error("The goal was cancelled.")
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
    state.shell.error(
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
          state.shell.error("Confirmed. The service makes the call on its next pass.")
          wait(state)

        {:error, reason} ->
          state.shell.error("Not confirmed (#{inspect(reason)}); the review stays held.")
          wait(state)
      end
    else
      state.shell.error(
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
    state.shell.error("Task #{task_id} is held: #{decision["explanation"]}")

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
          state.shell.error("Confirmed. The service admits it on its next pass.")
          wait(state)

        {:error, reason} ->
          state.shell.error("Not confirmed (#{inspect(reason)}); the task stays held.")
          wait(state)
      end
    else
      state.shell.error(
        "Left held. Run `shoestring follow #{state.goal_id}` to be asked again; " <>
          "the work stays queued."
      )

      {:ok, :held}
    end
  end

  defp needs_user(state, status) do
    state.shell.error("The work needs you:")

    if failure = status[:global_failure],
      do: state.shell.error("  The execution failed: #{inspect(failure, limit: 8)}")

    for review <- status[:reviews] || [], review.needs_user? do
      task = review.plan_task_id

      state.shell.error(
        "  The review of task #{task} (attempt #{review.attempt}) #{review_problem(review)}. " <>
          "Decide with `shoestring review accept|reject#{if review.state == "failed" and review.calls < 2, do: "|retry"} " <>
          "#{state.goal_id} #{task} --reason \"...\"`."
      )
    end

    for decision <- Shoestring.Decisions.list(goal_ids: [state.goal_id], states: ["pending"]) do
      short = String.slice(decision.id, 0, 8)

      state.shell.error(
        "  Task #{decision.plan_task_id} waits for you to choose: #{decision.question} " <>
          "See the candidates with `shoestring decision show #{short}` or on " <>
          "#{Shoestring.CLI.Commands.Decision.page_url(decision)}; answer with " <>
          "`shoestring decision answer #{short} --choose KEY`" <>
          if(decision.allow_reject, do: " or `--reject --note \"...\"`.", else: ".")
      )
    end

    for blocker <- status[:scope_blockers] || [] do
      state.shell.error(
        "  Scope blocker on #{blocker["plan_task_id"] || inspect(blocker, limit: 6)}"
      )
    end

    state.shell.error(
      "  See `shoestring execution status #{state.goal_id}`; resolve with " <>
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

  @page_size 500

  @doc false
  def page_size, do: @page_size

  @doc false
  def events_after(goal_id, sequence) do
    Repo.all(
      from e in TrajectoryEvent,
        where: e.goal_id == ^goal_id and e.sequence > ^sequence,
        order_by: [asc: e.sequence],
        limit: @page_size
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
        if p["result"] != "admit", do: "Waiting: " <> admission_wait(p)

      "cobbler.plan.admission.waiting" ->
        "Task #{task} is waiting: " <> waiting_reason(p)

      "cobbler.plan.capacity.confirmed" ->
        "Task #{task}: capacity confirmed by #{p["confirmed_by"]}."

      "run.completed" ->
        "  The worker finished; checking its work."

      "run.failed" ->
        if p["error_code"] == "supervisor_crash",
          do:
            "  Shoestring lost the worker during a service stop or crash; its exact stop time is unknown.",
          else: "  The worker failed (#{p["error_category"]}: #{p["error_code"]})."

      "run.cancelled" ->
        "  The worker was cancelled."

      "cobbler.plan.task.accepted" ->
        "Task #{task}: accepted at #{short(p["commit"])}."

      "cobbler.plan.decision.requested" ->
        "Task #{task}: waits for you to choose among #{length(p["options"] || [])} candidates: " <>
          "#{p["question"]} (shoestring decision show #{String.slice(p["decision_id"], 0, 8)})"

      "cobbler.plan.decision.answered" ->
        if p["answer"] == "reject",
          do: "Task #{task}: none of these, by #{p["decided_by"]}; it waits for your next step.",
          else: "Task #{task}: #{p["decided_by"]} chose #{p["option_key"]}."

      "cobbler.plan.decision.withdrawn" ->
        "Task #{task}: its decision was withdrawn (the goal was cancelled)."

      "cobbler.plan.task.gate_failed" ->
        case Regex.run(~r/\A\{:gate_unavailable, %\{reason: :(\w+)\}\}\z/, p["reason"] || "") do
          [_, "project_gate_not_configured"] ->
            "Task #{task}: check #{p["gate"]} is not configured; needs your decision."

          [_, reason] ->
            "Task #{task}: checks could not run in a sandbox (#{p["gate"]}: #{reason}); needs your decision."

          nil ->
            if uncommitted?(p),
              do:
                "Task #{task}: the worker left its change uncommitted, so its checks could not " <>
                  "run (they run on its last commit); needs your decision.",
              else: "Task #{task}: checks failed (#{p["gate"]})." <> not_run(p["skipped"])
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
      text -> shell.error(text)
    end
  end

  defp waiting_reason(%{"reason" => reason, "provider_id" => provider})
       when reason in ["no_observation", "no_observation_for_provider"] do
    "no capacity reading for #{provider} yet. It starts when one arrives; check that the " <>
      "#{provider} CLI is installed and signed in and that its capacity monitor is enabled " <>
      "(config :shoestring, :capacity_monitors)."
  end

  defp waiting_reason(%{"reason" => "codex_collection_window_open"}),
    do:
      "its openai/ opencode model shares the ChatGPT subscription a Codex collection " <>
        "window is measuring. It starts once that window is closed."

  defp waiting_reason(%{"reason" => reason, "provider_id" => provider}),
    do:
      "capacity for #{provider} could not be checked (#{reason}); the service retries every minute."

  # The admission's own explanation is written for Shoestring's operators;
  # the two a person meets most often are said plainly. At Settings'
  # parallel tasks 2 or more the decision records why it waits.
  defp admission_wait(%{
         "reason_code" => "scope_occupied",
         "extensions" => %{"shoestring.parallel:wait" => %{"limit" => limit} = wait}
       })
       when is_integer(limit) do
    running =
      if wait["running"] == 1,
        do: "1 IMPLEMENT task is running",
        else: "#{wait["running"]} IMPLEMENT tasks are running"

    why =
      case wait["reason"] do
        "files_overlap" ->
          "#{running}, and this one's files may overlap one of them in this repository: " <>
            "separate dispatches run side by side only when both name separate files " <>
            "with --file and neither touches a shared file (lockfiles, configuration, " <>
            "migrations)."

        "claim" ->
          "another task holds the task claim (a planner, or a run started before " <>
            "Settings allowed #{limit} at once)."

        _ ->
          "#{running}, and Settings' parallel tasks allows #{limit} at once, so every " <>
            "place is taken."
      end

    why <> " This one starts when that changes; it checks every minute."
  end

  defp admission_wait(%{"reason_code" => "scope_occupied"}),
    do:
      "another task is running, and dispatches run one at a time: only the tasks of one " <>
        "batch dispatch (--tasks) run at once, when Settings' parallel tasks is 2 or more. " <>
        "This one starts when that one finishes; it checks every minute."

  defp admission_wait(%{"reason_code" => "stale_observation"} = p),
    do:
      "#{provider(p)}'s usage reading is out of date, so whether it has room is unknown. It " <>
        "starts when you start it, or once a fresh reading shows room."

  defp admission_wait(p), do: p["explanation"] || "not admitted yet."

  defp provider(p), do: get_in(p, ["candidate", "provider_id"]) || "Its provider"

  defp not_run(skipped) when is_list(skipped) and skipped != [],
    do: " Not run: #{Enum.join(skipped, ", ")}."

  defp not_run(_skipped), do: ""

  defp optional(%{"required" => false}), do: " (optional)"
  defp optional(_payload), do: ""

  # The checks run on the worker's last commit; a worktree with changes
  # left uncommitted is refused before any check runs.
  defp uncommitted?(p), do: String.starts_with?(p["reason"] || "", "{:gate_worktree_dirty,")

  defp gate_result(p) do
    if uncommitted?(p),
      do: "not run: the worker left its change uncommitted",
      else: result_text(p)
  end

  defp result_text(p) do
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
