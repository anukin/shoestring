defmodule Shoestring.Cobbler.PlanScopeResolution do
  @moduledoc """
  Explicit human resolution of one fan-out scope blocker.

  A blocked attempt keeps its passed gates, tested commit and branch. A human
  then decides exactly one of:

  - `accept`: the tested commit counts as the task's accepted result, and the
    recorded blockers (by value) stop blocking later fan-out assessments. Any
    other overlap still blocks. Integration stays a human Git operation.
  - `reject`: the attempt resolves as failed. Its retry state is computed from
    the plan's attempt limits, so a replacement can only follow through normal
    admission, and only while attempts remain.

  The decision, validation and append share one immediate transaction behind
  the serialized writer, so a coordinator never observes a half-applied
  resolution. Replaying the identical command converges; a different decision
  for the same attempt is refused. Superseding the plan through an approved
  amendment remains the alternative to either decision.
  """

  import Ecto.Query

  alias Shoestring.Cobbler.{PlanExecutor, Plans, ReservationWriter}
  alias Shoestring.{Repo, Trajectory}
  alias Shoestring.Trajectory.TrajectoryEvent

  @type_name "cobbler.plan.task.scope_resolved"
  @human ~r/\Ahuman:[A-Za-z0-9][A-Za-z0-9_.@:+-]{0,180}\z/

  @spec resolve(Ecto.UUID.t(), map(), keyword()) :: {:ok, TrajectoryEvent.t()} | {:error, term()}
  def resolve(goal_id, attrs, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, goal_id} <- Ecto.UUID.cast(goal_id),
         {:ok, command} <- command(attrs) do
      ReservationWriter.run(repo, fn ->
        repo.transaction(
          fn ->
            case decide(repo, goal_id, command) do
              {:ok, event} -> event
              {:error, reason} -> repo.rollback(reason)
            end
          end,
          mode: :immediate
        )
      end)
      |> case do
        {:ok, event} ->
          publish(event, opts)
          {:ok, event}

        {:error, reason} ->
          {:error, reason}
      end
    else
      :error -> {:error, :invalid_scope_resolution}
      {:error, _} = error -> error
    end
  end

  defp command(attrs) do
    with {:ok, resolution_id} <- Ecto.UUID.cast(attrs[:command_id]),
         {:ok, execution_id} <- Ecto.UUID.cast(attrs[:execution_id]),
         task when is_binary(task) and task != "" <- attrs[:task_id],
         attempt when is_integer(attempt) and attempt > 0 <- attrs[:attempt],
         decision when decision in ["accept", "reject"] <- attrs[:decision],
         by when is_binary(by) <- attrs[:requested_by],
         true <- Regex.match?(@human, by),
         reason when is_binary(reason) <- attrs[:reason],
         reason = String.trim(reason),
         true <- reason != "" and String.length(reason) <= 2000 do
      {:ok,
       %{
         resolution_id: resolution_id,
         execution_id: execution_id,
         task_id: task,
         attempt: attempt,
         decision: decision,
         by: by,
         reason: reason
       }}
    else
      _ -> {:error, :invalid_scope_resolution}
    end
  end

  defp decide(repo, goal_id, command) do
    case existing(repo, goal_id, command) do
      %TrajectoryEvent{} = event ->
        if same_command?(event.payload, command),
          do: {:ok, event},
          else: {:error, :scope_resolution_conflict}

      nil ->
        record(repo, goal_id, command)
    end
  end

  defp record(repo, goal_id, command) do
    with {:ok, status} <- PlanExecutor.status(goal_id, repo: repo),
         %{execution: execution, completed?: false} <- status,
         true <- execution.execution_id == command.execution_id,
         %{revision: revision} <- Plans.authority(goal_id, repo: repo),
         true <-
           revision.revision_number == execution.revision_number and
             revision.digest == execution.plan_digest,
         %{} = blocked <-
           Enum.find(
             status.scope_blockers,
             &(&1.plan_task_id == command.task_id and &1.attempt == command.attempt)
           ),
         :ok <- acceptable(blocked, command.decision),
         {:ok, contract} <- Shoestring.Cobbler.PlanContract.new(revision.content) do
      payload =
        %{
          "resolution_id" => command.resolution_id,
          "execution_id" => execution.execution_id,
          "revision_number" => execution.revision_number,
          "plan_digest" => execution.plan_digest,
          "plan_task_id" => command.task_id,
          "attempt" => command.attempt,
          "run_id" => blocked.run_id,
          "blocked_event_id" => blocked.event_id,
          "decision" => command.decision,
          "resolved_by" => command.by,
          "reason" => command.reason
        }
        |> put_retry_state(command, status, contract)

      Trajectory.append(
        goal_id,
        %{
          "type" => @type_name,
          "schema_version" => 1,
          "actor" => "human",
          "occurred_at" => DateTime.utc_now(),
          "idempotency_key" => key(command),
          "payload" => payload
        },
        trusted: [run_id: blocked.run_id],
        writer_opts: [transaction_repo: repo]
      )
    else
      {:error, _} = error -> error
      _ -> {:error, :scope_resolution_mismatch}
    end
  end

  # Accepting needs the bounded final file set bound to the tested commit;
  # an attempt whose final scope could not be observed can only be rejected.
  defp acceptable(%{scope_json: json}, "accept") when is_binary(json), do: :ok
  defp acceptable(_blocked, "accept"), do: {:error, :final_scope_unavailable}
  defp acceptable(_blocked, "reject"), do: :ok

  defp put_retry_state(payload, %{decision: "accept"}, _status, _contract), do: payload

  defp put_retry_state(payload, command, status, contract) do
    task = Enum.find(contract.content["tasks"], &(&1["id"] == command.task_id))
    total_max = contract.content["budget"]["max_total_attempts"]

    state =
      cond do
        status.total_attempts >= total_max ->
          "needs_user"

        Map.get(status.attempts, command.task_id, 0) >= task["execution"]["max_attempts"] ->
          "escalate"

        true ->
          "retry"
      end

    Map.put(payload, "retry_state", state)
  end

  defp existing(repo, goal_id, command) do
    repo.one(
      from event in TrajectoryEvent,
        where: event.goal_id == ^goal_id and event.idempotency_key == ^key(command)
    )
  end

  defp same_command?(payload, command) do
    payload["resolution_id"] == command.resolution_id and
      payload["execution_id"] == command.execution_id and
      payload["decision"] == command.decision and payload["resolved_by"] == command.by and
      payload["reason"] == command.reason
  end

  defp key(command),
    do: "plan-scope-resolution:#{command.execution_id}:#{command.task_id}:#{command.attempt}"

  defp publish(event, opts) do
    publish =
      Keyword.get(opts, :publish_fun, fn event ->
        Phoenix.PubSub.broadcast(
          Shoestring.PubSub,
          Trajectory.topic(event.goal_id),
          {:trajectory_event_committed, event}
        )
      end)

    publish.(event)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
