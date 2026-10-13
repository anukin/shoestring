defmodule Shoestring.Cobbler.PlanCapacityConfirmation do
  @moduledoc "Human confirmation for one admission decision of one approved task attempt."
  import Ecto.Query
  alias Shoestring.{Repo, Trajectory}
  alias Shoestring.Cobbler.{PlanExecutor, Plans}
  alias Shoestring.Trajectory.TrajectoryEvent

  @type_name "cobbler.plan.capacity.confirmed"
  @extension "shoestring.plan:capacity_confirmation_id"
  def extension, do: @extension

  def confirm(goal_id, attrs) do
    with {:ok, goal_id} <- Ecto.UUID.cast(goal_id),
         {:ok, command_id} <- Ecto.UUID.cast(attrs[:command_id]),
         by when is_binary(by) <- attrs[:requested_by],
         true <- Regex.match?(~r/\Ahuman:[A-Za-z0-9][A-Za-z0-9_.@:+-]{0,180}\z/, by),
         {:ok, status} <- PlanExecutor.status(goal_id),
         %{execution: execution, completed?: false, needs_user?: false} <- status,
         true <- execution.execution_id == attrs[:execution_id],
         %{revision: revision} <- Plans.authority(goal_id),
         true <- revision.revision_number == execution.revision_number,
         true <- revision.digest == execution.plan_digest,
         {:ok, %{consistent?: true}} <- Plans.rebuild(goal_id),
         %{} = profile <- execution[:agent_profile],
         scope when is_binary(scope) <- attrs[:scope],
         true <- scope == Application.get_env(:shoestring, :run_submission_scope, "subscription"),
         %{} = task <- Enum.find(revision.content["tasks"], &(&1["id"] == attrs[:task_id])),
         true <- attrs[:attempt] == Map.get(status.attempts, task["id"], 0) + 1,
         true <- attrs[:attempt] <= task["execution"]["max_attempts"],
         true <- task["id"] not in status.accepted,
         true <- Enum.all?(task["depends_on"], &(&1 in status.accepted)),
         false <- Enum.any?(status.retirements, &(&1["task_id"] == task["id"])),
         true <- is_nil(status.active_run_id) do
      payload = %{
        "confirmation_id" => command_id,
        "execution_id" => execution.execution_id,
        "revision_number" => execution.revision_number,
        "plan_digest" => execution.plan_digest,
        "plan_task_id" => task["id"],
        "attempt" => attrs[:attempt],
        "provider_id" => profile["provider"],
        "adapter_id" => profile["adapter_id"],
        "scope" => scope,
        "confirmed_by" => by
      }

      append_confirmation(goal_id, command_id, payload)
    else
      _ -> {:error, :capacity_confirmation_mismatch}
    end
  end

  defp append_confirmation(goal_id, command_id, payload) do
    with {:ok, event} <-
           Trajectory.append(goal_id, %{
             type: @type_name,
             schema_version: 1,
             actor: "human",
             occurred_at: DateTime.utc_now(),
             idempotency_key: "plan-capacity-confirmation:#{command_id}",
             payload: payload
           }),
         true <- event.payload == payload do
      {:ok, event}
    else
      _ -> {:error, :capacity_confirmation_mismatch}
    end
  end

  def available(goal_id, execution, task, attempt, scope) do
    events =
      Repo.all(
        from e in TrajectoryEvent,
          where: e.goal_id == ^goal_id and e.type in [@type_name, "admission.decided"],
          order_by: [desc: e.sequence]
      )

    consumed =
      events
      |> Enum.filter(&(&1.type == "admission.decided"))
      |> MapSet.new(&get_in(&1.payload, ["extensions", @extension]))

    Enum.find(events, fn event ->
      p = event.payload

      event.type == @type_name and not MapSet.member?(consumed, event.id) and
        p["execution_id"] == execution.execution_id and
        p["revision_number"] == execution.revision_number and
        p["plan_digest"] == execution.plan_digest and p["plan_task_id"] == task["id"] and
        p["attempt"] == attempt and p["scope"] == scope and
        p["provider_id"] == execution.agent_profile["provider"] and
        p["adapter_id"] == execution.agent_profile["adapter_id"]
    end)
  end

  def evaluation_options(nil), do: []

  def evaluation_options(event),
    do: [decision_id: event.id, extensions: %{@extension => event.id}]

  def override(nil), do: nil

  def override(event) do
    %{
      "confirmed_by" => event.payload["confirmed_by"],
      "confirmed_at" => DateTime.to_iso8601(event.occurred_at),
      "target_provider_id" => event.payload["provider_id"],
      "target_scope" => event.payload["scope"],
      "intent" => "supervised_execution"
    }
  end
end
