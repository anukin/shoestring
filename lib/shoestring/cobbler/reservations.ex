defmodule Shoestring.Cobbler.Reservations do
  @moduledoc """
  Iteration 7 reservation foundation. This does not launch or authorize an Elf.

  One immediate SQLite write transaction checks all configured limits and
  persists ownership. Account usage spans goals and observations, so fresh or
  goal-local snapshot IDs cannot multiply the shared allowance. The caller must
  supply a trusted operator policy and an admitted canonical event; model
  proposals must never call this boundary or select policy/account identity.

  Identity is immutable across retries. Every held or reconciliation-required
  row counts. Deadlines only flag uncertainty; this module intentionally has no
  timer, replacement or cleanup path. Explicit reconciliation may settle verified
  terminal owners or no-intent orphans; atomic dispatch wiring remains required
  before production fan-out.
  """
  import Ecto.Query

  alias Shoestring.Cobbler.{
    AdmissionDecision,
    ReservationPolicy,
    ReservationRecord,
    ReservationReconciler,
    ReservationSettlementRecord
  }

  alias Shoestring.Harness.RunRecord
  alias Shoestring.Repo
  alias Shoestring.Trajectory.TrajectoryEvent

  @identity [:id, :goal_id, :execution_id, :plan_task_id, :attempt, :run_id, :admission_event_id]

  def hold(attrs, %ReservationPolicy{} = policy, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, identity} <- identity(attrs),
         {:ok, policy} <- ReservationPolicy.new(ReservationPolicy.to_map(policy)) do
      repo.transaction(
        fn ->
          case repo.get(ReservationRecord, identity.id) do
            nil -> acquire(repo, identity, policy, now)
            row -> replay(repo, row, identity, policy)
          end
        end,
        mode: :immediate
      )
    end
  end

  @doc "Reads durable owners, including overdue and explicitly uncertain owners."
  def outstanding(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    repo.all(
      from r in ReservationRecord,
        left_join: s in ReservationSettlementRecord,
        on: s.reservation_id == r.id,
        where: is_nil(s.reservation_id),
        order_by: [asc: r.inserted_at, asc: r.id]
    )
  end

  def reconcile(id, opts \\ []), do: ReservationReconciler.reconcile(id, opts)

  @doc false
  # Called inside intent/effect write transactions. Lookup by run ID also fences
  # callers that omit a reservation extension. Legacy unreserved runs are unchanged.
  def authorize(repo, run) do
    case repo.get_by(ReservationRecord, run_id: run.id) do
      nil ->
        :ok

      %{goal_id: goal_id} when goal_id != run.goal_id ->
        {:error, :reservation_owner_mismatch}

      row ->
        cond do
          repo.get(ReservationSettlementRecord, row.id) != nil ->
            {:error, :reservation_settled}

          row.status != "held" ->
            {:error, :reservation_requires_reconciliation}

          true ->
            event = repo.get!(TrajectoryEvent, row.admission_event_id)

            if event.payload["candidate"]["adapter_id"] == run.provider_id,
              do: :ok,
              else: {:error, :reservation_provider_mismatch}
        end
    end
  end

  @doc false
  # Reserved runs must use coordinator-owned continuation admission. Direct adapter
  # resume cannot race terminal settlement or revive consumption after release.
  def authorize_direct_resume(repo, run) do
    if repo.get_by(ReservationRecord, run_id: run.id),
      do: {:error, :reserved_run_requires_coordinator},
      else: :ok
  end

  @doc "Records uncertainty without releasing a slot or allowance. Idempotent for the same reason."
  def require_reconciliation(id, reason, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, id} <- Ecto.UUID.cast(id),
         true <- is_binary(reason) and String.trim(reason) != "" and byte_size(reason) <= 256 do
      repo.transaction(
        fn ->
          if repo.get(ReservationSettlementRecord, id), do: repo.rollback(:reservation_settled)

          case repo.get(ReservationRecord, id) do
            nil ->
              repo.rollback(:reservation_not_found)

            %{status: "held"} = row ->
              row
              |> Ecto.Changeset.change(
                status: "reconciliation_required",
                reconciliation_reason: reason,
                updated_at: now
              )
              |> repo.update!()

            %{reconciliation_reason: ^reason} = row ->
              row

            _ ->
              repo.rollback(:reconciliation_reason_mismatch)
          end
        end,
        mode: :immediate
      )
    else
      _ -> {:error, :invalid_reconciliation}
    end
  end

  defp identity(attrs) when is_map(attrs) do
    identity = Map.take(attrs, @identity)

    uuids =
      Enum.reduce_while(
        [:id, :goal_id, :execution_id, :run_id, :admission_event_id],
        identity,
        fn key, acc ->
          case Ecto.UUID.cast(Map.get(acc, key)) do
            {:ok, id} -> {:cont, Map.put(acc, key, id)}
            :error -> {:halt, :invalid}
          end
        end
      )

    if is_map(uuids) and is_binary(attrs[:plan_task_id]) and
         Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}\z/, attrs.plan_task_id) and
         is_integer(attrs[:attempt]) and attrs.attempt > 0 do
      {:ok, uuids}
    else
      {:error, :invalid_reservation_identity}
    end
  end

  defp identity(_), do: {:error, :invalid_reservation_identity}

  defp replay(repo, row, identity, policy) do
    cond do
      Map.take(row, @identity) != identity or
          row.concurrency_policy != ReservationPolicy.to_map(policy) ->
        repo.rollback(:reservation_identity_mismatch)

      repo.get(ReservationSettlementRecord, row.id) != nil ->
        repo.rollback(:reservation_settled)

      true ->
        row
    end
  end

  defp acquire(repo, identity, policy, now) do
    event = repo.get(TrajectoryEvent, identity.admission_event_id)

    with %TrajectoryEvent{goal_id: goal_id, type: "admission.decided", schema_version: 1} <- event,
         true <- goal_id == identity.goal_id,
         {:ok, decision} <- AdmissionDecision.from_payload(event.payload),
         true <-
           decision.result == :admit and decision.requested_capability == "supervised_execution",
         true <- is_nil(decision.run_id) or decision.run_id == identity.run_id,
         {:ok, snapshot_id} <- Ecto.UUID.cast(decision.observation["snapshot_id"]),
         true <- String.trim(decision.candidate.provider_id) != "",
         version when is_integer(version) and version > 0 <- decision.policy["version"],
         {:ok, deadline, _} <- parse_datetime(decision.proposed_bounds["deadline"]),
         true <-
           DateTime.compare(deadline, now) == :gt and
             DateTime.compare(decision.evaluated_at, now) != :gt do
      held = outstanding(repo: repo)
      if repo.get(RunRecord, identity.run_id), do: repo.rollback(:reservation_run_already_exists)
      enforce_limits(repo, held, identity, decision, policy)

      attrs =
        Map.merge(identity, %{
          provider_id: decision.candidate.provider_id,
          scope: decision.scope,
          snapshot_id: snapshot_id,
          observation_age_seconds: observation_age(decision.observation, now),
          admission_policy: decision.policy,
          concurrency_policy: ReservationPolicy.to_map(policy),
          units: policy.task_units,
          lease_bounds: decision.proposed_bounds,
          reconcile_after: deadline,
          inserted_at: now,
          updated_at: now
        })

      case repo.insert(ReservationRecord.hold_changeset(attrs)) do
        {:ok, row} -> row
        {:error, changeset} -> repo.rollback({:reservation_conflict, changeset})
      end
    else
      _ -> repo.rollback(:reservation_admission_mismatch)
    end
  end

  defp enforce_limits(repo, held, identity, decision, policy) do
    account =
      Enum.filter(
        held,
        &(&1.provider_id == decision.candidate.provider_id and &1.scope == decision.scope)
      )

    goal = Enum.filter(held, &(&1.goal_id == identity.goal_id))

    cond do
      Enum.any?(held, &(&1.concurrency_policy != ReservationPolicy.to_map(policy))) ->
        repo.rollback(:reservation_policy_change_requires_reconciliation)

      length(held) >= policy.global_limit ->
        repo.rollback({:reservation_blocked, :global_limit})

      length(account) >= policy.provider_account_limit ->
        repo.rollback({:reservation_blocked, :provider_account_limit})

      length(goal) >= policy.goal_limit ->
        repo.rollback({:reservation_blocked, :goal_limit})

      Enum.sum(Enum.map(account, & &1.units)) + policy.task_units > policy.account_units ->
        repo.rollback({:reservation_blocked, :account_units})

      true ->
        :ok
    end
  end

  defp observation_age(observation, now) do
    case parse_datetime(observation["observed_at"]) do
      {:ok, observed_at, _} -> max(DateTime.diff(now, observed_at), 0)
      _ -> nil
    end
  end

  defp parse_datetime(value) when is_binary(value), do: DateTime.from_iso8601(value)
  defp parse_datetime(_), do: {:error, :invalid_datetime}
end
