defmodule Shoestring.Decisions.NextStep do
  @moduledoc """
  What a decision's pane shows once the person has chosen: the plan's next
  task may be held for the person's confirmation (its provider's remaining
  usage could not be read), and the pane offers that one confirmation so
  the person does not need a terminal for it. Otherwise the pane is done.

  `step/2` is read only. `confirm/3` records the same confirmation as
  `shoestring execution confirm-capacity`, for the task the plan would
  start next, then queues the plan. Nothing here acts on a timer.
  """

  alias Shoestring.Cobbler.ExecutionControl
  alias Shoestring.Decisions.Decision

  @type step ::
          :done
          | :starting
          | {:confirm, %{task_id: String.t(), title: String.t(), why: String.t() | nil}}
          | {:deferred, %{title: String.t(), until: String.t() | nil, why: String.t() | nil}}
          | {:blocked, %{title: String.t(), why: String.t() | nil}}

  @doc """
  `:done` (nothing more for the person here), `:starting` (chosen; the plan
  is working out whether it may start its next task), `{:confirm, task}`
  (the next task waits for the person's OK), `{:deferred, task}` (it waits
  for its provider's usage to reset and starts by itself; nothing for the
  person to do) or `{:blocked, task}` (admission refused it).
  """
  @spec step(Decision.t(), keyword()) :: step()
  def step(decision, opts \\ [])

  def step(%Decision{state: "answered"} = decision, opts) do
    status_fun = Keyword.get(opts, :status, &ExecutionControl.status/1)

    with {:ok, status} <- status_fun.(decision.goal_id),
         %{execution: %{execution_id: execution_id}} <- status,
         true <- execution_id == decision.execution_id,
         false <- status.completed? or status.needs_user? or status[:cancelled?] == true,
         nil <- status.active_task,
         task_id when is_binary(task_id) <- status[:ready_task] do
      admission = status[:last_admission] || %{}

      cond do
        admission["result"] == "require_confirmation" and not status[:hold_confirmed?] ->
          {:confirm,
           %{
             task_id: task_id,
             title: task_title(decision.goal_id, task_id),
             why: why(admission)
           }}

        admission["result"] in [nil, "admit", "require_confirmation"] ->
          :starting

        admission["result"] == "defer_until" ->
          {:deferred,
           %{
             title: task_title(decision.goal_id, task_id),
             until: admission["defer_until"],
             why: admission["explanation"]
           }}

        true ->
          {:blocked,
           %{title: task_title(decision.goal_id, task_id), why: admission["explanation"]}}
      end
    else
      _ -> :done
    end
  end

  def step(%Decision{}, _opts), do: :done

  @doc """
  Confirms the next task the pane offered, as `by` (a person), and queues
  the plan. `{:ok, task_id}` or `{:error, reason}`. Two clicks record one
  confirmation: its id is derived from the admission decision and `by`.
  """
  @spec confirm(Decision.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def confirm(%Decision{} = decision, by, opts \\ []) do
    status_fun = Keyword.get(opts, :status, &ExecutionControl.status/1)

    with {:confirm, %{task_id: task_id}} <- step(decision, opts),
         {:ok, status} <- status_fun.(decision.goal_id),
         admission_id when is_binary(admission_id) <-
           get_in(status, [:last_admission, "decision_id"]),
         {:ok, _event} <-
           ExecutionControl.confirm_capacity(decision.goal_id, %{
             execution_id: decision.execution_id,
             task_id: task_id,
             attempt: Map.get(status.attempts, task_id, 0) + 1,
             scope: Application.get_env(:shoestring, :run_submission_scope, "subscription"),
             command_id:
               Shoestring.Dispatches.uuid_for("decision-next:#{admission_id}:#{task_id}:#{by}"),
             requested_by: by
           }) do
      resume = Keyword.get(opts, :resume_fun, &ExecutionControl.continue/2)
      _ = resume.(decision.goal_id, decision.execution_id)
      {:ok, task_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :nothing_to_confirm}
    end
  end

  # In the person's words, not the admission's reason code.
  defp why(admission) do
    provider =
      case get_in(admission, ["candidate", "provider_id"]) do
        "claude" -> "Claude"
        "codex" -> "Codex"
        "opencode" -> "opencode"
        _ -> "the provider"
      end

    "Shoestring could not tell how much #{provider} usage is left, so it asks you before starting."
  end

  defp task_title(goal_id, task_id) do
    with %{revision: revision} <- Shoestring.Cobbler.Plans.authority(goal_id),
         %{"title" => title} <-
           Enum.find(revision.content["tasks"] || [], &(&1["id"] == task_id)) do
      title
    else
      _ -> task_id
    end
  end
end
