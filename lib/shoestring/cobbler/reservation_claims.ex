defmodule Shoestring.Cobbler.ReservationClaims do
  @moduledoc "Internal reservation-owned command authority; no process effects or goal-wide permission."
  import Ecto.Query
  alias Shoestring.Cobbler.{Command, Commands, PlanBinding, PlanContract, PlanExecutor, Plans}
  alias Shoestring.Cobbler.{ReservationRecord, Reservations, ReservationSettlementRecord}
  alias Shoestring.Harness.{ExecutionLeaseRecord, RunRecord}
  alias Shoestring.Trajectory.TrajectoryEvent

  # Legacy claims remain exclusive. The sequential reservation path may acquire
  # its own global claim only when it is the sole unresolved reservation.
  def legacy_authority(repo, goal_id, command, opts) do
    case Reservations.outstanding(repo: repo) do
      [] ->
        :ok

      [owner] ->
        if owner.id == Keyword.get(opts, :reservation_id) and owner.goal_id == goal_id and
             owner.admission_event_id == command.payload["admission_event_id"] and
             owner.status == "held",
           do: :ok,
           else: {:error, :reservation_ownership_held}

      _ ->
        {:error, :reservation_ownership_held}
    end
  end

  def claim(repo, goal_id, %Command{type: "task.claim"} = command, id) do
    with {:ok, owner} <- owner(repo, goal_id, command, id),
         {:ok, decision} <- admission(repo, goal_id, command),
         :ok <- unique_command(repo, goal_id, command, owner) do
      {:ok, result(owner, decision.decision_id)}
    end
  end

  def claim(_, _, _, _), do: {:error, :reservation_claim_required}

  def gate(repo, row, command, id, lease_opts) when is_list(lease_opts) do
    with {:ok, owner} <- owner(repo, row.goal_id, command, id),
         {:ok, decision} <- admission(repo, row.goal_id, command),
         true <- row.status == "resolved" and row.result == result(owner, decision.decision_id),
         :ok <- canonical_command(repo, row),
         :ok <- unique_command(repo, row.goal_id, command, owner),
         :ok <- grant_binding(repo, owner, lease_opts),
         :ok <- existing_run(repo, owner, lease_opts),
         :ok <- lease_owner(repo, owner, decision.decision_id) do
      {:ok, owner}
    else
      false -> {:error, :reservation_command_mismatch}
      error -> error
    end
  end

  def gate(_, _, _, _, _), do: {:error, :reservation_lease_required}

  defp owner(repo, goal_id, command, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %ReservationRecord{} = owner <- repo.get(ReservationRecord, id),
         true <- owner.goal_id == goal_id and owner.parent_id == nil,
         true <- owner.admission_event_id == command.payload["admission_event_id"],
         nil <- repo.get(ReservationSettlementRecord, id),
         true <- owner.status == "held",
         nil <- Commands.active_claim(repo: repo) do
      {:ok, owner}
    else
      _ -> {:error, :reservation_claim_unavailable}
    end
  end

  defp admission(repo, goal_id, command) do
    case Commands.validate_admission_reference(repo, goal_id, command) do
      {:ok, decision} -> {:ok, decision}
      {:rejected, reason} -> {:error, {:reservation_admission_invalid, reason}}
    end
  end

  defp result(owner, decision_id) do
    %{
      "kind" => "reserved",
      "reservation_id" => owner.id,
      "execution_id" => owner.execution_id,
      "plan_task_id" => owner.plan_task_id,
      "attempt" => owner.attempt,
      "run_id" => owner.run_id,
      "provider_id" => owner.provider_id,
      "admission_event_id" => owner.admission_event_id,
      "admission_decision_id" => decision_id
    }
  end

  defp accepted(repo, goal_id) do
    repo.all(
      from e in TrajectoryEvent,
        where: e.goal_id == ^goal_id and e.type == "cobbler.command.accepted"
    )
  end

  defp unique_command(repo, goal_id, command, owner) do
    collision? =
      Enum.any?(accepted(repo, goal_id), fn event ->
        event.payload["result"]["reservation_id"] == owner.id and
          event.payload["command_id"] != command.command_id
      end)

    if collision?, do: {:error, :reservation_command_already_bound}, else: :ok
  end

  defp canonical_command(repo, row) do
    valid? =
      Enum.any?(accepted(repo, row.goal_id), fn event ->
        payload = event.payload

        payload["command_id"] == row.command_id and payload["command_digest"] == row.digest and
          payload["command_payload"] == row.payload and payload["to_status"] == row.status and
          payload["result"] == row.result
      end)

    if valid?, do: :ok, else: {:error, :reservation_command_not_canonical}
  end

  defp grant_binding(repo, owner, opts) do
    extensions = Keyword.get(opts, :extensions, %{})
    binding = extensions[PlanBinding.key()] || %{}

    with true <- Keyword.get(opts, :run_id) == owner.run_id,
         true <- extensions[Reservations.key()] == owner.id,
         true <- binding["execution_id"] == owner.execution_id,
         true <-
           binding["plan_task_id"] == owner.plan_task_id and binding["attempt"] == owner.attempt,
         %{revision: revision} <- Plans.authority(owner.goal_id, repo: repo),
         true <-
           revision.digest == binding["plan_digest"] and
             revision.revision_number == binding["revision_number"],
         {:ok, contract} <- PlanContract.new(revision.content),
         true <- owner.plan_task_id in PlanContract.required_task_ids(contract),
         {:ok, %{execution: %{execution_id: execution_id}} = status} <-
           PlanExecutor.status(owner.goal_id,
             repo: repo,
             now: Keyword.get(opts, :now, DateTime.utc_now())
           ),
         true <- execution_id == owner.execution_id,
         task = Enum.find(contract.content["tasks"], &(&1["id"] == owner.plan_task_id)),
         true <- Enum.all?(task["depends_on"], &(&1 in status.accepted)),
         true <- owner.plan_task_id not in status.accepted,
         true <- owner.attempt <= task["execution"]["max_attempts"],
         true <-
           owner.attempt == Map.get(status.attempts, owner.plan_task_id, 0) + 1 or
             not is_nil(repo.get(RunRecord, owner.run_id)) do
      :ok
    else
      _ -> {:error, :reservation_grant_binding_mismatch}
    end
  end

  defp existing_run(repo, owner, opts) do
    case repo.get(RunRecord, owner.run_id) do
      nil ->
        :ok

      run ->
        if run.goal_id == owner.goal_id and run.task_id == Keyword.get(opts, :task_id) and
             run.workspace_ref == Keyword.get(opts, :workspace_ref, "cobbler/lease") and
             run.extensions == Keyword.get(opts, :extensions, %{}) and
             run.dispatch_id == Keyword.get(opts, :dispatch_id),
           do: PlanBinding.authorize(repo, run),
           else: {:error, :reservation_run_replay_mismatch}
    end
  end

  # Lease replay is keyed by admission decision, so a duplicated decision UUID
  # in a different admission event must not share another child's grant.
  defp lease_owner(repo, owner, decision_id) do
    events =
      repo.all(
        from e in TrajectoryEvent,
          where: e.goal_id == ^owner.goal_id and e.type == "lease.proposed"
      )

    rows = repo.all(from l in ExecutionLeaseRecord, where: l.goal_id == ^owner.goal_id)

    foreign? =
      Enum.any?(events, fn e ->
        get_in(e.payload, ["extensions", "cobbler.lease:admission_decision_id"]) == decision_id and
          e.payload["run_id"] != owner.run_id
      end) or
        Enum.any?(rows, fn row ->
          row.extensions["cobbler.lease:admission_decision_id"] == decision_id and
            row.run_id != owner.run_id
        end)

    if foreign?, do: {:error, :reservation_admission_already_bound}, else: :ok
  end
end
