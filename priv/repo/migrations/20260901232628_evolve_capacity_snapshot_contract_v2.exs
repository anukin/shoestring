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
    UPDATE harness_capacity_snapshots
    SET
      contract_version = 2,
      capacity_state_v2 = CASE capacity_state WHEN 'known' THEN 'degraded' ELSE 'unknown' END,
      observed_at_v2 = observed_at,
      source_provider_id = 'legacy',
      source_invocation_mode = 'unknown',
      source_event = 'none',
      reason = 'legacy_capacity_contract_missing_provenance'
    """

    execute """
    UPDATE harness_capacity_windows
    SET
      state_v2 = CASE state WHEN 'known' THEN 'observed' ELSE 'unknown' END
    """
  end
end
