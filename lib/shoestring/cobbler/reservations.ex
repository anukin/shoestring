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

  @identity [
    :id,
    :goal_id,
    :execution_id,
    :plan_task_id,
    :attempt,
    :run_id,
    :admission_event_id,
    :parent_id
  ]
  @key "shoestring.reservation:id"
  def key, do: @key

  def hold(attrs, %ReservationPolicy{} = policy, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, identity} <- identity(attrs),
         {:ok, policy} <- ReservationPolicy.new(ReservationPolicy.to_map(policy)) do
      Shoestring.Cobbler.ReservationWriter.run(repo, fn ->
        repo.transaction(
          fn ->
            case repo.get(ReservationRecord, identity.id) do
              nil -> acquire(repo, identity, policy, now)
              row -> replay(repo, row, identity, policy)
            end
          end,
          mode: :immediate
        )
      end)
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

  @doc "Reconciles this goal's terminal owners at an explicit executor boundary."
  def reconcile_terminals(goal_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    terminal_ids =
      repo.all(
        from e in TrajectoryEvent,
          where:
            e.goal_id == ^goal_id and
              e.type in ~w(run.completed run.failed run.cancelled run.interrupted),
          select: e.run_id
      )
      |> MapSet.new()

    outstanding(repo: repo)
    |> Enum.filter(&(&1.goal_id == goal_id and MapSet.member?(terminal_ids, &1.run_id)))
    |> Enum.reduce_while(:ok, fn owner, :ok ->
      case reconcile(owner.id, opts) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc false
  # Called inside intent/effect write transactions. Lookup by run ID also fences
  # callers that omit a reservation extension. Legacy unreserved runs are unchanged.
  def authorize(repo, run) do
    case repo.get_by(ReservationRecord, run_id: run.id) do
      nil ->
        if Map.has_key?(run.extensions || %{}, @key),
          do: {:error, :reservation_missing},
          else: :ok

      %{goal_id: goal_id} when goal_id != run.goal_id ->
        {:error, :reservation_owner_mismatch}

      row ->
        cond do
          not binding_matches?(row, run) ->
            {:error, :reservation_binding_mismatch}

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

  defp binding_matches?(row, run) do
    extensions = run.extensions || %{}

    if Map.has_key?(extensions, @key) or is_map(extensions[Shoestring.Cobbler.PlanBinding.key()]) do
      binding = extensions[Shoestring.Cobbler.PlanBinding.key()] || %{}

      (not Map.has_key?(extensions, @key) or extensions[@key] == row.id) and
        binding["execution_id"] == row.execution_id and
        binding["plan_task_id"] == row.plan_task_id and binding["attempt"] == row.attempt
    else
      # Earlier explicit reservations may be unplanned; lookup by run ID still
      # enforces owner, settlement and provider fences for those callers.
      true
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
    identity = attrs |> Map.take(@identity) |> Map.put_new(:parent_id, nil)

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

    if is_map(uuids) and
         (is_nil(uuids.parent_id) or match?({:ok, _}, Ecto.UUID.cast(uuids.parent_id))) and
         is_binary(attrs[:plan_task_id]) and
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
         :ok <- parent_admission(repo, identity, decision),
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

  defp parent_admission(_repo, %{parent_id: nil} = identity, decision) do
    if is_nil(decision.run_id) or decision.run_id == identity.run_id,
      do: :ok,
      else: {:error, :reservation_admission_mismatch}
  end

  defp parent_admission(repo, identity, decision) do
    with %ReservationRecord{} = parent <- repo.get(ReservationRecord, identity.parent_id),
         true <-
           Map.take(parent, [:goal_id, :execution_id, :plan_task_id, :attempt]) ==
             Map.take(identity, [:goal_id, :execution_id, :plan_task_id, :attempt]),
         %ReservationSettlementRecord{kind: "consumed_closed"} <-
           repo.get(ReservationSettlementRecord, parent.id),
         true <- decision.run_id == parent.run_id,
         true <- identity.run_id != parent.run_id do
      :ok
    else
      _ -> {:error, :reservation_parent_mismatch}
    end
  end

  defp enforce_limits(repo, held, identity, decision, policy) do
    # The previous sequential claim may be released later in this same atomic
    # plan dispatch. A foreign legacy owner must never disappear from accounting.
    case Shoestring.Cobbler.Commands.active_claim(repo: repo) do
      %{goal_id: goal_id} when goal_id != identity.goal_id ->
        repo.rollback({:reservation_blocked, :legacy_claim})

      _ ->
        :ok
    end

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
