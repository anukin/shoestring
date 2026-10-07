defmodule Shoestring.Usage do
  @moduledoc "Read-only, account-scoped presentation of stored allowance observations."
  import Ecto.Query
  alias Shoestring.Repo
  alias Shoestring.Harness.{CapacitySnapshotRecord, Observatory, Security}

  def cards(now \\ DateTime.utc_now()) do
    goal_id = Observatory.observatory_goal_id()

    latest =
      from s in CapacitySnapshotRecord,
        where: s.goal_id == ^goal_id and s.contract_version == 2,
        group_by: [s.source_provider_id, s.scope],
        select: %{
          provider: s.source_provider_id,
          scope: s.scope,
          sequence: max(s.projection_sequence)
        }

    records =
      Repo.all(
        from s in CapacitySnapshotRecord,
          join: latest in subquery(latest),
          on:
            s.source_provider_id == latest.provider and s.scope == latest.scope and
              s.projection_sequence == latest.sequence,
          where: s.goal_id == ^goal_id and s.contract_version == 2,
          preload: [:windows]
      )

    cards = Enum.map(records, &card(&1, now))

    missing =
      Enum.reject(["claude", "codex"], fn provider ->
        Enum.any?(cards, &(&1.provider == provider))
      end)

    (cards ++ Enum.map(missing, &unknown/1)) |> Enum.sort_by(&{&1.provider, &1.scope})
  end

  defp card(record, now) do
    # Render defense for legacy rows: sanitise a copy, never the stored evidence.
    display_record = %{
      record
      | scope: Security.redact(record.scope),
        reason: redact_nullable(record.reason),
        windows:
          Enum.map(record.windows, &%{&1 | unknown_reason: redact_nullable(&1.unknown_reason)})
    }

    summary =
      display_record
      |> Observatory.record_to_snapshot()
      |> Observatory.observation_summary(now: now)

    status =
      cond do
        summary.capacity_state == :refused -> "Unavailable"
        summary.freshness_state == :stale -> "Stale"
        summary.freshness_state == :unknown or summary.capacity_state == :unknown -> "Unknown"
        summary.capacity_state == :degraded -> "Partial"
        true -> "Observed"
      end

    %{
      id: id(record.source_provider_id, record.scope),
      provider: record.source_provider_id,
      scope: Security.redact(record.scope),
      status: status,
      stale?: summary.freshness_state == :stale,
      reason: redact_nullable(summary.reason),
      observed_at: summary.observed_at,
      windows: windows(summary.windows),
      history: history(record, now)
    }
  end

  defp unknown(provider),
    do: %{
      id: id(provider, "unobserved"),
      provider: provider,
      scope: "No account observed",
      status: "Unknown",
      stale?: false,
      reason: "No saved allowance observation yet.",
      observed_at: nil,
      windows: windows([]),
      history: []
    }

  defp id(provider, scope),
    do: :crypto.hash(:sha256, provider <> ":" <> scope) |> Base.encode16(case: :lower)

  defp redact_nullable(nil), do: nil
  defp redact_nullable(value), do: Security.redact(value)

  defp windows(reported) do
    Enum.map(Enum.uniq(["five_hour", "seven_day"] ++ Enum.map(reported, & &1.kind)), fn kind ->
      Enum.find(reported, &(&1.kind == kind)) ||
        %{kind: kind, state: :unknown, used_percent: nil, reset_at: nil, reason: "Not reported"}
    end)
  end

  defp history(record, now) do
    start_date = Date.add(DateTime.to_date(now), -6)
    start_at = DateTime.new!(start_date, ~T[00:00:00], "Etc/UTC")

    rows =
      Repo.all(
        from s in CapacitySnapshotRecord,
          join: w in assoc(s, :windows),
          where:
            s.goal_id == ^record.goal_id and s.contract_version == 2 and
              s.source_provider_id == ^record.source_provider_id and s.scope == ^record.scope and
              s.observed_at >= ^start_at and s.observed_at <= ^now and w.kind == "five_hour" and
              w.state == "observed",
          group_by: fragment("date(?)", s.observed_at),
          select: {fragment("date(?)", s.observed_at), max(w.used_percent)}
      )
      |> Map.new()

    Enum.map(0..6, fn offset ->
      date = Date.add(start_date, offset)
      %{date: date, value: rows[Date.to_iso8601(date)]}
    end)
  end
end
