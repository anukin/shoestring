defmodule Shoestring.Cobbler.ReservationInspection do
  @moduledoc "Allowlisted read-only reservation and configured allowance views."
  import Ecto.Query

  alias Shoestring.Cobbler.{
    ReservationOperationRecord,
    ReservationRecord,
    ReservationSettlementRecord,
    Reservations
  }

  alias Shoestring.Harness.{
    CapacitySnapshotRecord,
    CapacityWindowRecord,
    DispatchRecord,
    RunRecord
  }

  alias Shoestring.Repo

  @reasons ~w(verified already_settled elf_running elf_ownership_unknown orphan_has_activity run_owner_mismatch run_not_terminal process_identity_missing process_identity_bound_exceeded activity_after_terminal process_identity_invalid process_group_alive process_group_unknown never_started_intent_fenced execution_evidence_present dispatch_effect_uncertain run_state_advanced)

  def list(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    goal_id = Keyword.get(opts, :goal_id)
    limit = Keyword.get(opts, :limit, 100)

    with true <- is_integer(limit) and limit in 1..1000,
         true <- is_nil(goal_id) or match?({:ok, _}, Ecto.UUID.cast(goal_id)) do
      query = from r in ReservationRecord, order_by: [asc: r.inserted_at, asc: r.id]
      query = if goal_id, do: from(r in query, where: r.goal_id == ^goal_id), else: query

      query =
        if Keyword.get(opts, :all, false),
          do: query,
          else:
            from(r in query,
              left_join: s in ReservationSettlementRecord,
              on: s.reservation_id == r.id,
              where: is_nil(s.reservation_id)
            )

      rows = repo.all(from r in query, limit: ^(limit + 1))
      held = Reservations.outstanding(repo: repo)

      {:ok,
       %{
         reservations: Enum.map(Enum.take(rows, limit), &view(&1, opts)),
         has_more: length(rows) > limit,
         configured_allowance: %{
           global_held: length(held),
           shared_units: Enum.sum(Enum.map(held, & &1.units)),
           units_are: "configured_concurrency_weights"
         }
       }}
    else
      _ -> {:error, :invalid_reservation_filter}
    end
  end

  def show(id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, id} <- Ecto.UUID.cast(id),
         %ReservationRecord{} = row <- repo.get(ReservationRecord, id) do
      {:ok, view(row, opts)}
    else
      _ -> {:error, :reservation_not_found}
    end
  end

  defp safe_result(nil), do: nil

  defp safe_result(result) do
    %{
      "disposition" =>
        if(result["disposition"] in ~w(released closed retained replayed),
          do: result["disposition"],
          else: "unrecognized"
        ),
      "reason" =>
        if(result["reason"] in @reasons,
          do: result["reason"],
          else: "operator_reconciliation_required"
        ),
      "settlement_kind" =>
        if(result["settlement_kind"] in ["released", "consumed_closed"],
          do: result["settlement_kind"]
        )
    }
  end

  defp view(row, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    settlement = repo.get(ReservationSettlementRecord, row.id)
    run = repo.get(RunRecord, row.run_id)
    dispatch = repo.get_by(DispatchRecord, run_id: row.run_id)
    snapshot = repo.get(CapacitySnapshotRecord, row.snapshot_id)
    held = Reservations.outstanding(repo: repo)
    account = Enum.filter(held, &(&1.provider_id == row.provider_id and &1.scope == row.scope))
    reason = row.reconciliation_reason

    %{
      id: row.id,
      parent_id: row.parent_id,
      goal_id: row.goal_id,
      execution_id: row.execution_id,
      plan_task_id: row.plan_task_id,
      attempt: row.attempt,
      run_id: row.run_id,
      provider_id: row.provider_id,
      scope: row.scope,
      status: if(settlement, do: settlement.kind, else: row.status),
      consumes_capacity: is_nil(settlement),
      reconciliation_reason:
        if(reason in @reasons,
          do: reason,
          else: if(reason, do: "operator_reconciliation_required")
        ),
      reconcile_after: row.reconcile_after,
      overdue: is_nil(settlement) and DateTime.compare(now, row.reconcile_after) != :lt,
      admission_event_id: row.admission_event_id,
      snapshot_id: row.snapshot_id,
      observation_age_at_grant_seconds: row.observation_age_seconds,
      configured_policy:
        Map.take(
          row.concurrency_policy,
          ~w(version global_limit provider_account_limit goal_limit account_units task_units)
        ),
      configured_units: row.units,
      occupancy: %{
        global: length(held),
        goal: Enum.count(held, &(&1.goal_id == row.goal_id)),
        provider_account: length(account),
        provider_account_units: Enum.sum(Enum.map(account, & &1.units))
      },
      run: run && Map.take(run, [:id, :status, :task_id, :dispatch_id]),
      dispatch: dispatch && Map.take(dispatch, [:dispatch_id, :status, :job_id]),
      capacity:
        if(snapshot,
          do: %{
            state: snapshot.capacity_state,
            observed_at: snapshot.observed_at,
            confidence: snapshot.confidence,
            windows:
              repo.all(from w in CapacityWindowRecord, where: w.snapshot_id == ^snapshot.id)
              |> Enum.map(&Map.take(&1, [:kind, :state, :used_percent, :reset_at]))
          },
          else: %{state: "not_projected"}
        ),
      settlement:
        settlement &&
          %{
            kind: settlement.kind,
            settled_at: settlement.settled_at,
            basis: settlement.evidence["basis"],
            terminal_event_id: settlement.evidence["terminal_event_id"],
            operation_id: settlement.evidence["operation_id"]
          },
      operations:
        repo.all(
          from o in ReservationOperationRecord,
            where: o.reservation_id == ^row.id,
            order_by: [asc: o.inserted_at, asc: o.id]
        )
        |> Enum.map(fn operation ->
          operation
          |> Map.take([:id, :action, :requested_by, :status])
          |> Map.put(:result, safe_result(operation.result))
        end)
    }
  end
end
