defmodule Shoestring.Cobbler.PlanHandoff do
  @moduledoc "Explicit saved-role authority for a cross-provider plan continuation."
  import Ecto.Query
  alias Shoestring.Cobbler.{ExecutionProfile, PlanBinding}
  alias Shoestring.Trajectory.TrajectoryEvent

  def selection(repo, sender, payload) do
    extensions = sender.extensions || %{}

    if is_map(extensions[PlanBinding.key()]) do
      with %{} = pinned <- extensions[ExecutionProfile.key()],
           role when is_binary(role) <- payload["receiver_role"],
           :ok <- ExecutionProfile.validate(pinned, repo),
           {:ok, receiver} <- ExecutionProfile.resolve(Map.put(pinned, "role", role), repo),
           true <- receiver["provider"] == payload["to_provider_id"],
           true <- receiver["adapter_id"] == payload["to_adapter_id"],
           true <- receiver["adapter_id"] != sender.provider_id do
        {:ok, receiver}
      else
        _ -> {:rejected, "handoff_receiver_role_mismatch"}
      end
    else
      if is_nil(payload["receiver_role"]),
        do: {:ok, nil},
        else: {:rejected, "handoff_execution_profile_required"}
    end
  end

  # Recheck canonical intent and plan authority BEFORE receiver observation.
  # A modified command cache or changed approval must produce no provider effect.
  def authorize_delivery(repo, sender, command, identity) do
    if is_map((sender.extensions || %{})[PlanBinding.key()]) do
      events =
        repo.all(
          from e in TrajectoryEvent,
            where: e.goal_id == ^sender.goal_id and e.type == "cobbler.command.accepted"
        )

      canonical =
        Enum.find(events, &(&1.payload["command_id"] == command.command_id))

      with %{payload: payload} <- canonical,
           true <- payload["command_type"] == "run.handoff",
           true <- payload["command_digest"] == command.digest,
           true <- payload["command_payload"] == command.payload,
           true <- payload["result"] == command.result,
           true <- payload["to_status"] == "resolved",
           true <- command.result["handoff_id"] == command.id,
           true <- command.result["run_id"] == sender.id,
           true <- command.result["checkpoint_id"] == command.payload["checkpoint_id"],
           {:ok, selected} <- selection(repo, sender, command.payload),
           true <- selected == command.result["receiver_profile"],
           true <- identity.adapter_id == selected["adapter_id"],
           true <- identity.provider == selected["provider"] do
        receiver = %{
          sender
          | id: command.id,
            dispatch_id: command.id,
            provider_id: identity.adapter_id,
            extensions: extensions(sender, command.result, command.id),
            continuation: %{"checkpoint_id" => command.result["checkpoint_id"]}
        }

        with :ok <- definitive_stop(repo, sender), do: PlanBinding.authorize(repo, receiver)
      else
        _ -> {:error, :plan_handoff_authority_mismatch}
      end
    else
      :ok
    end
  end

  defp definitive_stop(repo, sender) do
    stop =
      repo.one(
        from e in TrajectoryEvent,
          where:
            e.goal_id == ^sender.goal_id and e.run_id == ^sender.id and
              e.type in [
                "run.failed",
                "run.interrupted",
                "run.cancelled",
                "run.suspended",
                "run.completed"
              ],
          order_by: [desc: e.sequence],
          limit: 1
      )

    stopped? =
      case stop do
        %{type: "run.failed", payload: %{"error_category" => "quota_refused"}} -> true
        %{type: type} when type in ["run.interrupted", "run.cancelled"] -> true
        _ -> false
      end

    if stopped? and stop.idempotency_key == "elf-terminal:#{sender.dispatch_id}",
      do: :ok,
      else: {:error, :plan_handoff_parent_not_definitively_stopped}
  end

  def extensions(sender, intent, handoff_id) do
    extensions =
      (sender.extensions || %{})
      |> Map.delete("wakeup:resume_prior_session_id")
      |> Map.merge(%{
        "cobbler.handoff:handoff_id" => handoff_id,
        "cobbler.handoff:from_provider_id" => sender.provider_id,
        "cobbler.handoff:to_provider_id" => intent["to_provider_id"]
      })

    case intent["receiver_profile"] do
      nil -> extensions
      profile -> Map.put(extensions, ExecutionProfile.key(), profile)
    end
  end

  # Pure replay: a changed provider/profile is allowed only by the exact
  # canonical command that reserved this receiver's dispatch identity.
  def authorized?(parent, child, events) do
    left = parent.payload
    right = child.payload
    sender = get_in(left, ["extensions", ExecutionProfile.key()])
    receiver = get_in(right, ["extensions", ExecutionProfile.key()])
    handoff_id = get_in(right, ["extensions", "cobbler.handoff:handoff_id"])

    is_map(sender) and is_map(receiver) and is_binary(handoff_id) and
      right["dispatch_id"] == handoff_id and
      Map.take(sender, ~w(profile_id revision digest instructions)) ==
        Map.take(receiver, ~w(profile_id revision digest instructions)) and
      left["provider_id"] == sender["adapter_id"] and
      right["provider_id"] == receiver["adapter_id"] and
      left["provider_id"] != right["provider_id"] and
      definitively_stopped?(events, parent) and
      Enum.any?(events, fn event ->
        payload = event.payload
        result = payload["result"] || %{}
        intent = payload["command_payload"] || %{}

        event.type == "cobbler.command.accepted" and
          payload["command_type"] == "run.handoff" and payload["to_status"] == "resolved" and
          result["kind"] == "handoff_requested" and result["handoff_id"] == handoff_id and
          result["run_id"] == left["run_id"] and
          intent["run_id"] == result["run_id"] and
          intent["checkpoint_id"] == result["checkpoint_id"] and
          result["checkpoint_id"] == get_in(right, ["continuation", "checkpoint_id"]) and
          result["receiver_profile"] == receiver and
          intent["receiver_role"] == receiver["role"] and
          intent["to_provider_id"] == receiver["provider"] and
          intent["to_adapter_id"] == receiver["adapter_id"] and
          (not Map.has_key?(child, :sequence) or event.sequence < child.sequence)
      end)
  end

  defp definitively_stopped?(events, parent) do
    stop =
      events
      |> Enum.filter(
        &(&1.type in ~w(run.failed run.interrupted run.cancelled run.suspended run.completed) and
            &1.payload["run_id"] == parent.payload["run_id"])
      )
      |> List.last()

    case stop do
      %{idempotency_key: key, type: type, payload: payload} ->
        key == "elf-terminal:#{parent.payload["dispatch_id"]}" and
          (type in ~w(run.interrupted run.cancelled) or
             (type == "run.failed" and payload["error_category"] == "quota_refused"))

      _ ->
        false
    end
  end
end
