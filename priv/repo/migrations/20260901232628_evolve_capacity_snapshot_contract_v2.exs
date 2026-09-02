defmodule Shoestring.Repo.Migrations.EvolveCapacitySnapshotContractV2 do
  use Ecto.Migration

  def up do
    alter table(:harness_capacity_snapshots) do
      add :capacity_state_v2, :string,
        null: false,
        default: "unknown",
        check: %{
          name: "harness_capacity_snapshots_state_v2_valid",
          expr: "capacity_state_v2 IN ('observed', 'degraded', 'refused', 'unknown')"
        }

      add :observed_at_v2, :utc_datetime_usec

      add :freshness_max_age_seconds, :integer,
        null: false,
        default: 300,
        check: %{
          name: "harness_capacity_snapshots_freshness_positive",
          expr: "freshness_max_age_seconds > 0 AND freshness_max_age_seconds <= 86400"
        }

      add :source_provider_id, :string, null: false, default: "legacy"
      add :source_invocation_mode, :string, null: false, default: "unknown"

      add :source_event, :string,
        null: false,
        default: "none",
        check: %{
          name: "harness_capacity_snapshots_source_event_valid",
          expr:
            "source_event IN ('explicit_read', 'update_notification', 'status_line_input', 'headless_result_error', 'none')"
        }

      add :reason, :string, null: false, default: "legacy_capacity_contract_missing_provenance"
    end

    alter table(:harness_capacity_windows) do
      add :state_v2, :string,
        null: false,
        default: "unknown",
        check: %{
          name: "harness_capacity_windows_state_v2_valid",
          expr: "state_v2 IN ('observed', 'unknown')"
        }
    end

    execute """
    UPDATE harness_capacity_windows
    SET
      state_v2 = CASE state WHEN 'known' THEN 'observed' ELSE 'unknown' END
    """

    execute """
    UPDATE harness_capacity_snapshots
    SET
      contract_version = 2,
      capacity_state_v2 = CASE
        WHEN capacity_state = 'known'
          AND EXISTS (
            SELECT 1
            FROM harness_capacity_windows
            WHERE snapshot_id = harness_capacity_snapshots.id
              AND state = 'known'
          )
          THEN 'degraded'
        ELSE 'unknown'
      END,
      observed_at_v2 = observed_at,
      freshness_max_age_seconds = CASE
        WHEN expires_at IS NOT NULL
          AND CAST(strftime('%s', expires_at) AS INTEGER) >
              CAST(strftime('%s', observed_at) AS INTEGER)
          AND CAST(strftime('%s', expires_at) AS INTEGER) -
              CAST(strftime('%s', observed_at) AS INTEGER) <= 86400
          THEN CAST(strftime('%s', expires_at) AS INTEGER) -
               CAST(strftime('%s', observed_at) AS INTEGER)
        ELSE 300
      END,
      source_provider_id = 'legacy',
      source_invocation_mode = 'unknown',
      source_event = 'none',
      confidence = CASE
        WHEN capacity_state = 'known'
          AND EXISTS (
            SELECT 1
            FROM harness_capacity_windows
            WHERE snapshot_id = harness_capacity_snapshots.id
              AND state = 'known'
          )
          AND confidence = 'none'
          THEN 'low'
        WHEN capacity_state = 'known'
          AND EXISTS (
            SELECT 1
            FROM harness_capacity_windows
            WHERE snapshot_id = harness_capacity_snapshots.id
              AND state = 'known'
          )
          THEN confidence
        ELSE 'none'
      END,
      support_tier = CASE support_tier
        WHEN 'unsupported' THEN 'unsupported'
        ELSE 'conservative_partial'
      END,
      reason = 'legacy_capacity_contract_missing_provenance'
    """
  end
end
