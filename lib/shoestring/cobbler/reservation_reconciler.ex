defmodule Shoestring.Cobbler.ReservationReconciler do
  @moduledoc """
  Explicit, read-only ownership reconciliation followed by durable settlement.

  No timer, cancellation, replacement or job pruning occurs. Target groups are
  only probed with signal zero; a bounded local helper owns its own cleanup.
  `effect_completed` is delivery evidence, not proof that a run stopped. A
  terminal event plus absent Elf and absent recorded process groups is required
  to close consumption. Missing/invalid process identities and probe errors are
  uncertainty. A no-intent orphan may be released under the same write lock as
  the intent-creation fence. Existing ambiguous intents remain reserved.
  """
  import Ecto.Query
  alias Shoestring.Cobbler.{GateProcess, ReservationRecord, ReservationSettlementRecord}
  alias Shoestring.Harness.{DispatchRecord, RunRecord}
  alias Shoestring.Repo
  alias Shoestring.Trajectory.TrajectoryEvent

  @terminals ~w(run.completed run.failed run.cancelled run.interrupted)
  @max_groups 64
  @probe_script """
  import errno, os, sys
  result = 0
  for value in sys.argv[1:]:
      try:
          os.killpg(int(value), 0)
          result = 1
      except OSError as error:
          if error.errno != errno.ESRCH:
              result = 2
              break
  sys.exit(result)
  """

  def reconcile(id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, id} <- Ecto.UUID.cast(id) do
      Shoestring.Cobbler.ReservationWriter.run(repo, fn ->
        repo.transaction(
          fn ->
            case repo.get(ReservationRecord, id) do
              nil -> repo.rollback(:reservation_not_found)
              row -> reconcile_row(repo, row, now, opts)
            end
          end,
          mode: :immediate
        )
      end)
    else
      _ -> {:error, :invalid_reservation_identity}
    end
  end

  defp reconcile_row(repo, row, now, opts) do
    case repo.get(ReservationSettlementRecord, row.id) do
      %ReservationSettlementRecord{} = settlement ->
        result(:replayed, row, settlement, :already_settled)

      nil ->
        case observe(repo, row, opts) do
          {:settle, kind, evidence} ->
            settlement =
              ReservationSettlementRecord.changeset(%{
                reservation_id: row.id,
                kind: kind,
                settled_at: now,
                evidence: Map.put(evidence, "version", 1)
              })
              |> repo.insert!()

            result(
              if(kind == "released", do: :released, else: :closed),
              row,
              settlement,
              :verified
            )

          {:retain, reason, uncertain?} ->
            row =
              if uncertain? and row.status == "held" do
                row
                |> Ecto.Changeset.change(
                  status: "reconciliation_required",
                  reconciliation_reason: Atom.to_string(reason),
                  updated_at: now
                )
                |> repo.update!()
              else
                row
              end

            result(:retained, row, nil, reason)
        end
    end
  end

  defp observe(repo, row, opts) do
    lookup = Keyword.get(opts, :elf_lookup, &Shoestring.Elves.whereis/1)

    case safely(fn -> lookup.(row.run_id) end) do
      nil -> inspect_intent(repo, row, opts)
      pid when is_pid(pid) -> {:retain, :elf_running, false}
      _ -> {:retain, :elf_ownership_unknown, true}
    end
  end

  defp inspect_intent(repo, row, opts) do
    case repo.get(RunRecord, row.run_id) do
      nil ->
        activity? = repo.exists?(from e in TrajectoryEvent, where: e.run_id == ^row.run_id)
        dispatch? = repo.exists?(from d in DispatchRecord, where: d.run_id == ^row.run_id)

        if activity? or dispatch? do
          {:retain, :orphan_has_activity, true}
        else
          {:settle, "released", %{"basis" => "no_run_intent_or_activity"}}
        end

      %RunRecord{goal_id: goal_id} = run when goal_id == row.goal_id ->
        inspect_terminal(repo, run, opts)

      _ ->
        {:retain, :run_owner_mismatch, true}
    end
  end

  defp inspect_terminal(repo, run, opts) do
    terminal =
      repo.one(
        from e in TrajectoryEvent,
          where: e.goal_id == ^run.goal_id and e.run_id == ^run.id and e.type in ^@terminals,
          order_by: [desc: e.sequence],
          limit: 1
      )

    if terminal && terminal.payload["run_id"] == run.id do
      running =
        repo.all(
          from e in TrajectoryEvent,
            where: e.goal_id == ^run.goal_id and e.run_id == ^run.id and e.type == "run.running",
            order_by: [desc: e.sequence],
            limit: @max_groups + 1
        )

      inspect_groups(running, terminal, opts)
    else
      {:retain, :run_not_terminal, false}
    end
  end

  defp inspect_groups(running, terminal, opts) do
    parsed = Enum.map(running, &parse_group(&1.payload["process_id"]))

    cond do
      running == [] ->
        {:retain, :process_identity_missing, true}

      length(running) > @max_groups ->
        {:retain, :process_identity_bound_exceeded, true}

      Enum.any?(running, &(&1.sequence >= terminal.sequence)) ->
        {:retain, :activity_after_terminal, true}

      Enum.any?(parsed, &(&1 == :invalid)) ->
        {:retain, :process_identity_invalid, true}

      true ->
        groups = Enum.uniq(parsed)
        probe = Keyword.get(opts, :group_probe, &probe_groups/1)

        case safely(fn -> probe.(groups) end) do
          :absent ->
            {:settle, "consumed_closed",
             %{
               "basis" => "terminal_and_owned_groups_absent",
               "terminal_event_id" => terminal.id,
               "running_event_ids" => Enum.map(running, & &1.id),
               "group_count" => length(groups),
               "elf_present" => false,
               "process_groups" => "absent"
             }}

          :alive ->
            {:retain, :process_group_alive, true}

          _ ->
            {:retain, :process_group_unknown, true}
        end
    end
  end

  defp parse_group("pgid:" <> digits), do: parse_group(digits)

  defp parse_group(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 1 and number <= 2_147_483_647 -> number
      _ -> :invalid
    end
  end

  defp parse_group(_), do: :invalid

  @doc false
  def probe_groups(groups)
      when is_list(groups) and groups != [] and length(groups) <= @max_groups do
    if Enum.all?(groups, &(is_integer(&1) and &1 > 1 and &1 <= 2_147_483_647)) do
      argv = ["python3", "-I", "-S", "-c", @probe_script | Enum.map(groups, &Integer.to_string/1)]

      case GateProcess.run(argv, System.tmp_dir!(), 2_000, 1024) do
        {:ok, %{exit_status: 0}} -> :absent
        {:ok, %{exit_status: 1}} -> :alive
        _ -> :unknown
      end
    else
      :unknown
    end
  end

  def probe_groups(_), do: :unknown

  defp safely(fun) do
    fun.()
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end

  defp result(disposition, row, settlement, reason),
    do: %{disposition: disposition, reservation: row, settlement: settlement, reason: reason}
end
