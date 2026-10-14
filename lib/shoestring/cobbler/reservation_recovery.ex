defmodule Shoestring.Cobbler.ReservationRecovery do
  @moduledoc "Explicit never-started cancellation; uncertain or possibly started owners stay held."
  import Ecto.Query
  alias Shoestring.Cobbler.{ReservationSettlementRecord, Reservations}
  alias Shoestring.Harness.{DispatchRecord, RunRecord}
  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.TrajectoryEvent

  # Only harmless initial intent/grant history is compatible with never-started.
  @intent_types ~w(run.requested lease.proposed lease.granted lease.active dispatch.requested cobbler.plan.task.dispatched)

  def cancel_unstarted(owner, operation_id, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    unless repo.in_transaction?(),
      do: raise(ArgumentError, "recovery requires a write transaction")

    lookup = Keyword.get(opts, :elf_lookup, &Shoestring.Elves.whereis/1)

    case repo.get(ReservationSettlementRecord, owner.id) do
      nil ->
        case safely(fn -> lookup.(owner.run_id) end) do
          nil -> inspect_intent(repo, owner, operation_id, opts)
          pid when is_pid(pid) -> retained(owner, :elf_running)
          _ -> uncertain(owner, :elf_ownership_unknown, opts)
        end

      settlement ->
        %{disposition: :replayed, reason: :already_settled, settlement: settlement}
    end
  end

  defp inspect_intent(repo, owner, operation_id, opts) do
    case repo.get(RunRecord, owner.run_id) do
      nil ->
        {:ok, result} = Reservations.reconcile(owner.id, opts)
        result

      %{goal_id: goal_id, status: "requested"} = run when goal_id == owner.goal_id ->
        activity? =
          repo.exists?(
            from e in TrajectoryEvent, where: e.run_id == ^run.id and e.type not in ^@intent_types
          )

        dispatches = repo.all(from d in DispatchRecord, where: d.run_id == ^run.id)

        cond do
          activity? ->
            uncertain(owner, :execution_evidence_present, opts)

          not safe_dispatches?(dispatches, run) ->
            uncertain(owner, :dispatch_effect_uncertain, opts)

          true ->
            fence(repo, owner, run, dispatches, operation_id, opts)
        end

      %{goal_id: goal_id} when goal_id != owner.goal_id ->
        uncertain(owner, :run_owner_mismatch, opts)

      _ ->
        uncertain(owner, :run_state_advanced, opts)
    end
  end

  defp safe_dispatches?([], _), do: true

  defp safe_dispatches?([dispatch], run) do
    dispatch.goal_id == run.goal_id and dispatch.task_id == run.task_id and
      dispatch.dispatch_id == run.dispatch_id and dispatch.status in ["requested", "cancelled"] and
      is_nil(dispatch.outcome_at) and is_nil(dispatch.outcome_code)
  end

  defp safe_dispatches?(_, _), do: false

  defp fence(repo, owner, run, dispatches, operation_id, opts) do
    now = Keyword.fetch!(opts, :now)

    case Shoestring.Harness.Runs.reconcile_run(
           run,
           Keyword.put(opts, :writer_opts, transaction_repo: repo)
         ) do
      :ok -> :ok
      {:ok, :repaired} -> :ok
      {:error, reason} -> repo.rollback(reason)
    end

    Enum.each(dispatches, fn dispatch ->
      dispatch |> DispatchRecord.status_changeset("cancelled", now) |> repo.update!()
    end)

    for {type, key} <- [
          {"run.cancelling", "elf-cancelling:#{run.dispatch_id}"},
          {"run.cancelled", "elf-terminal:#{run.dispatch_id}"}
        ] do
      case Trajectory.append(
             run.goal_id,
             %{
               "type" => type,
               "schema_version" => 1,
               "actor" => "cobbler",
               "occurred_at" => now,
               "idempotency_key" => key,
               "payload" => %{"run_id" => run.id}
             },
             trusted: [task_id: run.task_id, run_id: run.id],
             writer_opts: [transaction_repo: repo]
           ) do
        {:ok, _} -> :ok
        {:error, reason} -> repo.rollback(reason)
      end
    end

    # Settlement is the late-intent/effect fence. Job status is not proof and
    # no process group is signalled or inferred absent from a timeout.
    settlement =
      ReservationSettlementRecord.changeset(%{
        reservation_id: owner.id,
        kind: "released",
        settled_at: now,
        evidence: %{
          "version" => 1,
          "basis" => "never_started_intent_fenced",
          "operation_id" => operation_id,
          "dispatch_ids" => Enum.map(dispatches, & &1.dispatch_id),
          "elf_present" => false
        }
      })
      |> repo.insert!()

    %{disposition: :released, reason: :never_started_intent_fenced, settlement: settlement}
  end

  defp uncertain(owner, reason, opts) do
    if owner.status == "held" do
      {:ok, _} = Reservations.require_reconciliation(owner.id, Atom.to_string(reason), opts)
    end

    retained(owner, reason)
  end

  defp retained(_owner, reason), do: %{disposition: :retained, reason: reason, settlement: nil}

  defp safely(fun) do
    fun.()
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end
end
