defmodule Shoestring.Repo.Migrations.EvolveCapacitySnapshotContractV2 do
  use Ecto.Migration

  # SQLite cannot add a table-level constraint with ALTER TABLE. The window
  # table is therefore rebuilt in both directions so the state/data invariant
  # is enforced by the schema, including for direct SQL writers.
  #
  # This migration is intentionally non-transactional because the down path
  # must toggle SQLite foreign_keys while rebuilding the referenced snapshots
  # table. SQLite ignores that PRAGMA inside a transaction. The up path keeps
  # foreign keys enabled and is made recoverable by retaining the original v1
  # values in rollback-only archive columns; Ecto cannot express different
  # transaction settings for up and down. Handwritten rebuild DDL deliberately
  # uses the same SQLite affinities as Ecto's types (BLOB UUIDs, TEXT strings,
  # FLOAT percentages, and DATETIME timestamps).
  @disable_ddl_transaction true

  @legacy_reason "legacy_capacity_contract_missing_provenance"

  def up do
    alter table(:harness_capacity_snapshots) do
      # There is deliberately no default here. New observed rows omit reason
      # and must persist NULL; only existing rows receive the legacy reason.
      add :reason, :string
      add :legacy_capacity_state_v1, :string
      add :legacy_expires_at_v1, :utc_datetime_usec
      add :legacy_confidence_v1, :string
      add :legacy_support_tier_v1, :string
      add :legacy_compatibility_state_v1, :string
      add :legacy_source_method_v1, :string
    end

    execute("""
    UPDATE harness_capacity_snapshots
    SET
      reason = '#{@legacy_reason}',
      legacy_capacity_state_v1 = capacity_state,
      legacy_expires_at_v1 = expires_at,
      legacy_confidence_v1 = confidence,
      legacy_support_tier_v1 = support_tier,
      legacy_compatibility_state_v1 = compatibility_state,
      legacy_source_method_v1 = source_method
    WHERE reason IS NULL
    """)

    execute("""
    UPDATE harness_capacity_snapshots
    SET
      legacy_capacity_state_v1 = capacity_state,
      legacy_expires_at_v1 = expires_at,
      legacy_confidence_v1 = confidence,
      legacy_support_tier_v1 = support_tier,
      legacy_compatibility_state_v1 = compatibility_state,
      legacy_source_method_v1 = source_method
    WHERE legacy_capacity_state_v1 IS NULL
    """)

    alter table(:harness_capacity_snapshots) do
      add :capacity_state_v2, :string,
        null: false,
        default: "unknown",
        check: %{
          name: "harness_capacity_snapshots_state_v2_valid",
          expr: """
          capacity_state_v2 IN ('observed', 'degraded', 'refused', 'unknown')
          AND (
            (capacity_state_v2 = 'observed' AND reason IS NULL)
            OR
            (capacity_state_v2 IN ('degraded', 'refused', 'unknown')
             AND reason IS NOT NULL AND length(trim(reason)) > 0)
          )
          AND NOT (capacity_state_v2 = 'refused' AND support_tier = 'unsupported')
          AND NOT (capacity_state_v2 = 'observed' AND support_tier <> 'proactive')
          AND NOT (capacity_state_v2 = 'refused' AND confidence = 'high')
          """
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
    end

    rebuild_windows_up()

    execute("""
    CREATE TRIGGER harness_capacity_windows_refused_observed_insert
    BEFORE INSERT ON harness_capacity_windows
    WHEN NEW.state_v2 = 'observed'
      AND EXISTS (
        SELECT 1 FROM harness_capacity_snapshots
        WHERE id = NEW.snapshot_id AND capacity_state_v2 = 'refused'
      )
    BEGIN
      SELECT RAISE(ABORT, 'refused capacity cannot contain observed windows');
    END
    """)

    execute("""
    CREATE TRIGGER harness_capacity_windows_refused_observed_update
    BEFORE UPDATE OF snapshot_id, state_v2 ON harness_capacity_windows
    WHEN NEW.state_v2 = 'observed'
      AND EXISTS (
        SELECT 1 FROM harness_capacity_snapshots
        WHERE id = NEW.snapshot_id AND capacity_state_v2 = 'refused'
      )
    BEGIN
      SELECT RAISE(ABORT, 'refused capacity cannot contain observed windows');
    END
    """)

    execute("""
    CREATE TRIGGER harness_capacity_snapshots_refused_observed_update
    BEFORE UPDATE OF capacity_state_v2 ON harness_capacity_snapshots
    WHEN NEW.capacity_state_v2 = 'refused'
      AND EXISTS (
        SELECT 1 FROM harness_capacity_windows
        WHERE snapshot_id = NEW.id AND state_v2 = 'observed'
      )
    BEGIN
      SELECT RAISE(ABORT, 'refused capacity cannot contain observed windows');
    END
    """)

    execute("""
    UPDATE harness_capacity_snapshots
    SET
      contract_version = 2,
      capacity_state_v2 = CASE
        WHEN capacity_state = 'known'
          AND julianday(observed_at) <= julianday(inserted_at)
          AND EXISTS (
            SELECT 1
            FROM harness_capacity_windows
            WHERE snapshot_id = harness_capacity_snapshots.id
              AND state_v2 = 'observed'
          )
          THEN 'degraded'
        ELSE 'unknown'
      END,
      -- Legacy shadow state is canonical fail-closed output. This migration
      -- cannot establish a proactive observed v2 source, so it is unknown;
      -- rollback uses legacy_capacity_state_v1 to restore the old value.
      capacity_state = 'unknown',
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
      source_method = 'none',
      confidence = CASE
        WHEN capacity_state = 'known'
          AND EXISTS (
            SELECT 1
            FROM harness_capacity_windows
            WHERE snapshot_id = harness_capacity_snapshots.id
              AND state_v2 = 'observed'
          )
          AND confidence = 'none'
          THEN 'low'
        WHEN capacity_state = 'known'
          AND EXISTS (
            SELECT 1
            FROM harness_capacity_windows
            WHERE snapshot_id = harness_capacity_snapshots.id
              AND state_v2 = 'observed'
          )
          THEN confidence
        ELSE 'none'
      END,
      support_tier = CASE support_tier
        WHEN 'unsupported' THEN 'unsupported'
        ELSE 'conservative_partial'
      END,
      compatibility_state = 'degraded',
      reason = CASE
        WHEN julianday(observed_at) > julianday(inserted_at)
          THEN 'legacy_capacity_observation_after_event'
        ELSE '#{@legacy_reason}'
      END
    """)

    # Recompute the legacy nullable expiry from the backfilled freshness so
    # invalid or missing legacy expiries agree with the event upcaster.
    execute("""
    UPDATE harness_capacity_snapshots
    SET expires_at =
      strftime('%Y-%m-%dT%H:%M:%S', observed_at,
        '+' || freshness_max_age_seconds || ' seconds') ||
      CASE
        WHEN instr(observed_at, '.') > 0
          AND substr(observed_at, instr(observed_at, '.') + 1, 6) <> '000000'
          THEN substr(observed_at, instr(observed_at, '.'), 7)
        ELSE ''
      END || 'Z'
    WHERE observed_at IS NOT NULL
    """)

    execute("PRAGMA foreign_keys = ON")
  end

  def down do
    # Restore the exact v1 values captured before the canonical v2 backfill.
    # Rows created after the migration have NULL archive values and therefore
    # use conservative v1 fallbacks in the rebuild helpers below.
    execute("PRAGMA foreign_keys = OFF")

    execute("DROP TRIGGER IF EXISTS harness_capacity_windows_refused_observed_insert")
    execute("DROP TRIGGER IF EXISTS harness_capacity_windows_refused_observed_update")
    execute("DROP TRIGGER IF EXISTS harness_capacity_snapshots_refused_observed_update")

    rebuild_windows_down()
    rebuild_snapshots_down()

    execute("PRAGMA foreign_keys = ON")
  end

  defp rebuild_windows_up do
    execute("""
    CREATE TABLE harness_capacity_windows_v2 (
      id BLOB NOT NULL PRIMARY KEY,
      snapshot_id BLOB NOT NULL
        REFERENCES harness_capacity_snapshots(id) ON DELETE CASCADE,
      kind TEXT NOT NULL,
      state TEXT NOT NULL
        CONSTRAINT harness_capacity_windows_state_valid
        CHECK (state IN ('known', 'unknown')),
      legacy_state_v1 TEXT,
      legacy_used_percent_v1 FLOAT,
      legacy_reset_at_v1 DATETIME,
      legacy_unknown_reason_v1 TEXT,
      used_percent FLOAT
        CONSTRAINT harness_capacity_windows_used_percent_range
        CHECK (used_percent IS NULL OR (used_percent >= 0 AND used_percent <= 100)),
      reset_at DATETIME,
      unknown_reason TEXT,
      inserted_at DATETIME NOT NULL,
      updated_at DATETIME NOT NULL,
      state_v2 TEXT NOT NULL
        CONSTRAINT harness_capacity_windows_state_v2_valid
        CHECK (
          state_v2 IN ('observed', 'unknown')
          AND (
            (state_v2 = 'observed'
             AND used_percent IS NOT NULL
             AND used_percent >= 0 AND used_percent <= 100
             AND unknown_reason IS NULL)
            OR
            (state_v2 = 'unknown'
             AND used_percent IS NULL
             AND unknown_reason IS NOT NULL
             AND length(trim(unknown_reason)) > 0)
          )
        )
    )
    """)

    execute("""
    INSERT INTO harness_capacity_windows_v2
      (id, snapshot_id, kind, state, legacy_state_v1, legacy_used_percent_v1,
       legacy_reset_at_v1, legacy_unknown_reason_v1, used_percent, reset_at,
       unknown_reason, inserted_at, updated_at, state_v2)
    SELECT
      w.id,
      w.snapshot_id,
      w.kind,
      'unknown',
      w.state,
      w.used_percent,
      w.reset_at,
      w.unknown_reason,
      CASE
        WHEN julianday(s.observed_at) <= julianday(s.inserted_at)
          AND w.state = 'known'
          AND w.used_percent IS NOT NULL
          AND w.used_percent >= 0 AND w.used_percent <= 100
          THEN w.used_percent
        ELSE NULL
      END,
      CASE
        WHEN julianday(s.observed_at) <= julianday(s.inserted_at)
          AND w.state = 'known'
          AND w.used_percent IS NOT NULL
          AND w.used_percent >= 0 AND w.used_percent <= 100
          THEN w.reset_at
        ELSE NULL
      END,
      CASE
        WHEN julianday(s.observed_at) > julianday(s.inserted_at)
          THEN 'legacy_capacity_observation_after_event'
        WHEN w.state = 'known'
          AND w.used_percent IS NOT NULL
          AND w.used_percent >= 0 AND w.used_percent <= 100
          THEN NULL
        ELSE COALESCE(NULLIF(trim(w.unknown_reason), ''), '#{@legacy_reason}')
      END,
      w.inserted_at,
      w.updated_at,
      CASE
        WHEN julianday(s.observed_at) <= julianday(s.inserted_at)
          AND w.state = 'known'
          AND w.used_percent IS NOT NULL
          AND w.used_percent >= 0 AND w.used_percent <= 100
          THEN 'observed'
        ELSE 'unknown'
      END
    FROM harness_capacity_windows AS w
      JOIN harness_capacity_snapshots AS s ON s.id = w.snapshot_id
    """)

    execute("DROP TABLE harness_capacity_windows")
    execute("ALTER TABLE harness_capacity_windows_v2 RENAME TO harness_capacity_windows")
    create unique_index(:harness_capacity_windows, [:snapshot_id, :kind])
    create index(:harness_capacity_windows, [:reset_at])
  end

  defp rebuild_windows_down do
    execute("""
    CREATE TABLE harness_capacity_windows_legacy (
      id BLOB NOT NULL PRIMARY KEY,
      snapshot_id BLOB NOT NULL
        REFERENCES harness_capacity_snapshots(id) ON DELETE CASCADE,
      kind TEXT NOT NULL,
      state TEXT NOT NULL
        CONSTRAINT harness_capacity_windows_state_valid
        CHECK (state IN ('known', 'unknown')),
      used_percent FLOAT
        CONSTRAINT harness_capacity_windows_used_percent_range
        CHECK (used_percent IS NULL OR (used_percent >= 0 AND used_percent <= 100)),
      reset_at DATETIME,
      unknown_reason TEXT,
      inserted_at DATETIME NOT NULL,
      updated_at DATETIME NOT NULL
    )
    """)

    execute("""
    INSERT INTO harness_capacity_windows_legacy
      (id, snapshot_id, kind, state, used_percent, reset_at, unknown_reason,
       inserted_at, updated_at)
    SELECT
      id,
      snapshot_id,
      kind,
      CASE WHEN legacy_state_v1 IN ('known', 'unknown') THEN legacy_state_v1 ELSE 'unknown' END,
      CASE WHEN legacy_state_v1 IS NOT NULL THEN legacy_used_percent_v1 ELSE NULL END,
      CASE WHEN legacy_state_v1 IS NOT NULL THEN legacy_reset_at_v1 ELSE NULL END,
      CASE
        WHEN legacy_state_v1 IS NOT NULL THEN legacy_unknown_reason_v1
        ELSE COALESCE(NULLIF(trim(unknown_reason), ''), 'v2_capacity_contract_downcast')
      END,
      inserted_at,
      updated_at
    FROM harness_capacity_windows
    """)

    execute("DROP TABLE harness_capacity_windows")
    execute("ALTER TABLE harness_capacity_windows_legacy RENAME TO harness_capacity_windows")
    create unique_index(:harness_capacity_windows, [:snapshot_id, :kind])
    create index(:harness_capacity_windows, [:reset_at])
  end

  defp rebuild_snapshots_down do
    execute("""
    CREATE TABLE harness_capacity_snapshots_legacy (
      id BLOB NOT NULL PRIMARY KEY,
      goal_id BLOB NOT NULL
        REFERENCES goals(id) ON DELETE CASCADE,
      run_id BLOB REFERENCES harness_runs(id) ON DELETE SET NULL,
      contract_version INTEGER NOT NULL
        CONSTRAINT harness_capacity_snapshots_version_positive
        CHECK (contract_version > 0),
      capacity_state TEXT NOT NULL
        CONSTRAINT harness_capacity_snapshots_state_valid
        CHECK (capacity_state IN ('known', 'unknown')),
      observed_at DATETIME NOT NULL,
      expires_at DATETIME,
      source_adapter_id TEXT NOT NULL,
      source_method TEXT NOT NULL,
      scope TEXT NOT NULL,
      confidence TEXT NOT NULL,
      support_tier TEXT NOT NULL,
      compatibility_state TEXT NOT NULL,
      extensions BLOB NOT NULL,
      projection_sequence INTEGER NOT NULL,
      inserted_at DATETIME NOT NULL,
      updated_at DATETIME NOT NULL
    )
    """)

    execute("""
    INSERT INTO harness_capacity_snapshots_legacy
      (id, goal_id, run_id, contract_version, capacity_state, observed_at,
       expires_at, source_adapter_id, source_method, scope, confidence,
       support_tier, compatibility_state, extensions, projection_sequence,
       inserted_at, updated_at)
    SELECT
      id,
      goal_id,
      run_id,
      1,
      CASE
        WHEN legacy_capacity_state_v1 IN ('known', 'unknown') THEN legacy_capacity_state_v1
        ELSE 'unknown'
      END,
      observed_at,
      CASE
        WHEN legacy_capacity_state_v1 IS NOT NULL THEN legacy_expires_at_v1
        ELSE expires_at
      END,
      source_adapter_id,
      CASE
        WHEN legacy_source_method_v1 IS NOT NULL THEN legacy_source_method_v1
        ELSE 'none'
      END,
      scope,
      COALESCE(legacy_confidence_v1, 'none'),
      CASE
        WHEN legacy_support_tier_v1 IN ('supported', 'partial', 'unsupported')
          THEN legacy_support_tier_v1
        WHEN support_tier = 'unsupported' THEN 'unsupported'
        ELSE 'partial'
      END,
      CASE
        WHEN legacy_compatibility_state_v1 IN ('compatible', 'degraded', 'incompatible')
          THEN legacy_compatibility_state_v1
        WHEN compatibility_state = 'incompatible' THEN 'incompatible'
        ELSE 'degraded'
      END,
      extensions,
      projection_sequence,
      inserted_at,
      updated_at
    FROM harness_capacity_snapshots
    """)

    execute("DROP TABLE harness_capacity_snapshots")
    execute("ALTER TABLE harness_capacity_snapshots_legacy RENAME TO harness_capacity_snapshots")
    create index(:harness_capacity_snapshots, [:goal_id, :observed_at])
    create index(:harness_capacity_snapshots, [:run_id, :observed_at])
    create index(:harness_capacity_snapshots, [:compatibility_state, :support_tier])
  end
end
