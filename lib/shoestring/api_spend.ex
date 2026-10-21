defmodule Shoestring.ApiSpend do
  @moduledoc """
  Deterministic, zero-default spend reservations before one external API call.

  Immediate SQLite transactions serialize independent instances. Outstanding
  calls occupy allowance in every month until trustworthy usage arrives. A
  call spanning month boundaries is conservatively booked in both its start
  and reconciliation months. No time limit or restart releases allowance.
  """
  import Ecto.Query
  alias Shoestring.ApiSpend.{Pricing, Reservation}
  alias Shoestring.Harness.{RunRecord, RunRequest}
  alias Shoestring.Repo

  def policy do
    config = Application.get_env(:shoestring, :api_execution, %{})

    cond do
      not is_map(config) ->
        {:error, :invalid_api_policy}

      config[:enabled] != true ->
        {:error, :api_disabled}

      not is_integer(config[:monthly_cap_microusd]) or config[:monthly_cap_microusd] <= 0 ->
        {:error, :api_zero_cap}

      config[:monthly_cap_microusd] > 1_000_000_000_000 ->
        {:error, :invalid_api_policy}

      true ->
        {:ok, config}
    end
  end

  def reserve(%RunRequest{} = request, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, config} <- policy(),
         {:ok, pricing, maximum} <- Pricing.quote(config, now) do
      repo.transaction(
        fn ->
          run =
            repo.get_by(RunRecord,
              dispatch_id: request.dispatch_id,
              goal_id: request.goal_id,
              task_id: request.task_id,
              workspace_ref: request.workspace_ref
            )

          if is_nil(run), do: repo.rollback(:api_run_not_owned)
          if run.provider_id != "openai_responses", do: repo.rollback(:api_provider_mismatch)

          if repo.get(Reservation, request.dispatch_id),
            do: repo.rollback(:api_call_already_reserved)

          if occupied(repo, month(now)) + maximum > config[:monthly_cap_microusd],
            do: repo.rollback(:api_cap_exceeded)

          attrs = %{
            id: request.dispatch_id,
            goal_id: run.goal_id,
            run_id: run.id,
            version: 1,
            pricing: pricing,
            maximum_microusd: maximum,
            monthly_cap_microusd: config[:monthly_cap_microusd],
            reserved_at: now,
            reserved_month: month(now),
            status: "reserved"
          }

          case repo.insert(Reservation.changeset(%Reservation{}, attrs)) do
            {:ok, row} -> row
            {:error, _} -> repo.rollback(:api_reservation_write_failed)
          end
        end,
        mode: :immediate
      )
    end
  end

  @doc "Reconcile only bounded usage counters, using the immutable original price quote."
  def reconcile(call_id, usage, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    repo.transaction(
      fn ->
        row = repo.get(Reservation, call_id) || repo.rollback(:api_reservation_not_found)

        case Pricing.usage_amount(row.pricing, usage) do
          {:ok, amount} ->
            cond do
              row.status == "reconciled" and row.input_tokens == usage["input_tokens"] and
                  row.output_tokens == usage["output_tokens"] ->
                row

              row.status == "reconciled" ->
                repo.rollback(:api_usage_conflict)

              DateTime.compare(now, row.reserved_at) == :lt ->
                repo.rollback(:api_reconciliation_before_reservation)

              true ->
                update!(repo, row, %{
                  status: "reconciled",
                  input_tokens: usage["input_tokens"],
                  output_tokens: usage["output_tokens"],
                  reconciled_microusd: amount,
                  reconciled_at: now,
                  reconciled_month: month(now)
                })
            end

          {:error, _} ->
            if row.status == "reconciled", do: repo.rollback(:api_usage_conflict)
            update!(repo, row, %{status: "unresolved"})
        end
      end,
      mode: :immediate
    )
  end

  @doc "Mark uncertainty without releasing a single reserved unit. Idempotent after restart."
  def unresolved(call_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    repo.transaction(
      fn ->
        row = repo.get(Reservation, call_id) || repo.rollback(:api_reservation_not_found)
        if row.status == "reconciled", do: row, else: update!(repo, row, %{status: "unresolved"})
      end,
      mode: :immediate
    )
  end

  def summary(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    config = Application.get_env(:shoestring, :api_execution, %{})

    cap =
      if is_map(config) and is_integer(config[:monthly_cap_microusd]),
        do: max(config[:monthly_cap_microusd], 0),
        else: 0

    repo.transaction(fn ->
      reserved =
        repo.one(
          from r in Reservation, where: r.status != "reconciled", select: sum(r.maximum_microusd)
        ) || 0

      spent = occupied(repo, month(now)) - reserved

      %{
        "version" => 1,
        "currency" => "USD",
        "unit" => "microusd",
        "month" => month(now),
        "enabled" => match?({:ok, _}, policy()),
        "cap_microusd" => cap,
        "reserved_microusd" => reserved,
        "reconciled_upper_microusd" => spent,
        "over_cap_microusd" => max(reserved + spent - cap, 0),
        "remaining_microusd" => max(cap - reserved - spent, 0)
      }
    end)
  end

  defp occupied(repo, month) do
    repo.one(
      from r in Reservation,
        select:
          sum(
            fragment(
              "CASE WHEN ? != 'reconciled' THEN ? WHEN ? = ? OR ? = ? THEN ? ELSE 0 END",
              r.status,
              r.maximum_microusd,
              r.reserved_month,
              ^month,
              r.reconciled_month,
              ^month,
              r.reconciled_microusd
            )
          )
    ) || 0
  end

  defp update!(repo, row, attrs) do
    case repo.update(Reservation.changeset(row, attrs)) do
      {:ok, updated} -> updated
      {:error, _} -> repo.rollback(:api_reservation_write_failed)
    end
  end

  defp month(now),
    do:
      now
      |> DateTime.shift_zone!("Etc/UTC")
      |> DateTime.to_date()
      |> Date.to_iso8601()
      |> binary_part(0, 7)
end
