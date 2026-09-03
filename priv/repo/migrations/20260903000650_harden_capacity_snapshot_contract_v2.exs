defmodule Shoestring.Repo.Migrations.HardenCapacitySnapshotContractV2 do
  use Ecto.Migration

  # SQLite cannot add table-level constraints or change nullability with ALTER TABLE.
  # The snapshot and window tables are therefore rebuilt in both directions so the
  # state/reason, refusal, and window invariants are enforced by the schema.
  #
  # This migration is intentionally non-transactional because rebuilding referenced
  # tables in SQLite requires toggling the foreign_keys PRAGMA, which SQLite ignores
  # inside a transaction.
  @disable_ddl_transaction true

  @legacy_reason "legacy_capacity_contract_missing_provenance"

  def up do
    execute("PRAGMA foreign_keys = OFF")

    rebuild_windows_up()
    rebuild_snapshots_up()

    create_triggers()

    execute("PRAGMA foreign_keys = ON")
    execute("PRAGMA foreign_key_check")
  end

  def down do
    execute("PRAGMA foreign_keys = OFF")

    drop_triggers()

    rebuild_windows_down()
    rebuild_snapshots_down()

    execute("PRAGMA foreign_keys = ON")
    execute("PRAGMA foreign_key_check")
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

  defp rebuild_snapshots_up do
    execute("""
    CREATE TABLE harness_capacity_snapshots_v2 (
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
      updated_at DATETIME NOT NULL,
      capacity_state_v2 TEXT NOT NULL
        CONSTRAINT harness_capacity_snapshots_state_v2_valid
        CHECK (
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
        ),
      observed_at_v2 DATETIME,
      freshness_max_age_seconds INTEGER NOT NULL DEFAULT 300
        CONSTRAINT harness_capacity_snapshots_freshness_positive
        CHECK (freshness_max_age_seconds > 0 AND freshness_max_age_seconds <= 86400),
      source_provider_id TEXT NOT NULL DEFAULT 'legacy',
      source_invocation_mode TEXT NOT NULL DEFAULT 'unknown',
      source_event TEXT NOT NULL DEFAULT 'none'
        CONSTRAINT harness_capacity_snapshots_source_event_valid
        CHECK (
          source_event IN ('explicit_read', 'update_notification', 'status_line_input', 'headless_result_error', 'none')
        ),
      reason TEXT,
      legacy_capacity_state_v1 TEXT,
      legacy_expires_at_v1 DATETIME,
      legacy_confidence_v1 TEXT,
      legacy_support_tier_v1 TEXT,
      legacy_compatibility_state_v1 TEXT,
      legacy_source_method_v1 TEXT
    )
    """)

    execute("""
    INSERT INTO harness_capacity_snapshots_v2
      (id, goal_id, run_id, contract_version, capacity_state, observed_at,
       expires_at, source_adapter_id, source_method, scope, confidence,
       support_tier, compatibility_state, extensions, projection_sequence,
       inserted_at, updated_at, capacity_state_v2, observed_at_v2,
       freshness_max_age_seconds, source_provider_id, source_invocation_mode,
       source_event, reason, legacy_capacity_state_v1, legacy_expires_at_v1,
       legacy_confidence_v1, legacy_support_tier_v1, legacy_compatibility_state_v1,
       legacy_source_method_v1)
    SELECT
      s.id,
      s.goal_id,
      s.run_id,
      2,
      'unknown',
      s.observed_at,
      CASE
        WHEN s.observed_at IS NOT NULL
          THEN strftime('%Y-%m-%dT%H:%M:%S', s.observed_at,
            '+' ||
            CASE
              WHEN s.expires_at IS NOT NULL
                AND CAST(strftime('%s', s.expires_at) AS INTEGER) >
                    CAST(strftime('%s', s.observed_at) AS INTEGER)
                AND CAST(strftime('%s', s.expires_at) AS INTEGER) -
                    CAST(strftime('%s', s.observed_at) AS INTEGER) <= 86400
                THEN CAST(strftime('%s', s.expires_at) AS INTEGER) -
                     CAST(strftime('%s', s.observed_at) AS INTEGER)
              ELSE 300
            END || ' seconds') ||
            CASE
              WHEN instr(s.observed_at, '.') > 0
                AND substr(s.observed_at, instr(s.observed_at, '.') + 1, 6) <> '000000'
                THEN substr(s.observed_at, instr(s.observed_at, '.'), 7)
              ELSE ''
            END || 'Z'
        ELSE s.expires_at
      END,
      s.source_adapter_id,
      'none',
      s.scope,
      CASE
        WHEN s.capacity_state = 'known'
          AND EXISTS (
            SELECT 1
            FROM harness_capacity_windows
            WHERE snapshot_id = s.id
              AND state_v2 = 'observed'
          )
          AND s.confidence = 'none'
          THEN 'low'
        WHEN s.capacity_state = 'known'
          AND EXISTS (
            SELECT 1
            FROM harness_capacity_windows
            WHERE snapshot_id = s.id
              AND state_v2 = 'observed'
          )
          THEN s.confidence
        ELSE 'none'
      END,
      CASE
        WHEN s.support_tier = 'unsupported' THEN 'unsupported'
        ELSE 'conservative_partial'
      END,
      'degraded',
      s.extensions,
      s.projection_sequence,
      s.inserted_at,
      s.updated_at,
      CASE
        WHEN s.capacity_state = 'known'
          AND julianday(s.observed_at) <= julianday(s.inserted_at)
          AND EXISTS (
            SELECT 1
            FROM harness_capacity_windows
            WHERE snapshot_id = s.id
              AND state_v2 = 'observed'
          )
          THEN 'degraded'
        ELSE 'unknown'
      END,
      s.observed_at,
      CASE
        WHEN s.expires_at IS NOT NULL
          AND CAST(strftime('%s', s.expires_at) AS INTEGER) >
              CAST(strftime('%s', s.observed_at) AS INTEGER)
          AND CAST(strftime('%s', s.expires_at) AS INTEGER) -
              CAST(strftime('%s', s.observed_at) AS INTEGER) <= 86400
          THEN CAST(strftime('%s', s.expires_at) AS INTEGER) -
               CAST(strftime('%s', s.observed_at) AS INTEGER)
        ELSE 300
      END,
      s.source_provider_id,
      s.source_invocation_mode,
      s.source_event,
      CASE
        WHEN julianday(s.observed_at) > julianday(s.inserted_at)
          THEN 'legacy_capacity_observation_after_event'
        ELSE '#{@legacy_reason}'
      END,
      s.capacity_state,
      s.expires_at,
      s.confidence,
      s.support_tier,
      s.compatibility_state,
      s.source_method
    FROM harness_capacity_snapshots AS s
    """)

    execute("DROP TABLE harness_capacity_snapshots")
    execute("ALTER TABLE harness_capacity_snapshots_v2 RENAME TO harness_capacity_snapshots")
    create index(:harness_capacity_snapshots, [:goal_id, :observed_at])
    create index(:harness_capacity_snapshots, [:run_id, :observed_at])
    create index(:harness_capacity_snapshots, [:compatibility_state, :support_tier])
  end

  defp create_triggers do
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
  end

  defp drop_triggers do
    execute("DROP TRIGGER IF EXISTS harness_capacity_windows_refused_observed_insert")
    execute("DROP TRIGGER IF EXISTS harness_capacity_windows_refused_observed_update")
    execute("DROP TRIGGER IF EXISTS harness_capacity_snapshots_refused_observed_update")
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
      updated_at DATETIME NOT NULL,
      state_v2 TEXT NOT NULL
        CONSTRAINT harness_capacity_windows_state_v2_valid
        CHECK (state_v2 IN ('observed', 'unknown'))
    )
    """)

    execute("""
    INSERT INTO harness_capacity_windows_legacy
      (id, snapshot_id, kind, state, used_percent, reset_at, unknown_reason,
       inserted_at, updated_at, state_v2)
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
      updated_at,
      state_v2
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
      updated_at DATETIME NOT NULL,
      capacity_state_v2 TEXT NOT NULL
        CONSTRAINT harness_capacity_snapshots_state_v2_valid
        CHECK (capacity_state_v2 IN ('observed', 'degraded', 'refused', 'unknown')),
      observed_at_v2 DATETIME,
      freshness_max_age_seconds INTEGER NOT NULL DEFAULT 300
        CONSTRAINT harness_capacity_snapshots_freshness_positive
        CHECK (freshness_max_age_seconds > 0 AND freshness_max_age_seconds <= 86400),
      source_provider_id TEXT NOT NULL DEFAULT 'legacy',
      source_invocation_mode TEXT NOT NULL DEFAULT 'unknown',
      source_event TEXT NOT NULL DEFAULT 'none'
        CONSTRAINT harness_capacity_snapshots_source_event_valid
        CHECK (
          source_event IN ('explicit_read', 'update_notification', 'status_line_input', 'headless_result_error', 'none')
        ),
      reason TEXT NOT NULL DEFAULT 'legacy_capacity_contract_missing_provenance'
    )
    """)

    execute("""
    INSERT INTO harness_capacity_snapshots_legacy
      (id, goal_id, run_id, contract_version, capacity_state, observed_at,
       expires_at, source_adapter_id, source_method, scope, confidence,
       support_tier, compatibility_state, extensions, projection_sequence,
       inserted_at, updated_at, capacity_state_v2, observed_at_v2,
       freshness_max_age_seconds, source_provider_id, source_invocation_mode,
       source_event, reason)
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
      updated_at,
      capacity_state_v2,
      observed_at_v2,
      freshness_max_age_seconds,
      source_provider_id,
      source_invocation_mode,
      source_event,
      COALESCE(reason, 'legacy_capacity_contract_missing_provenance')
    FROM harness_capacity_snapshots
    """)

    execute("DROP TABLE harness_capacity_snapshots")
    execute("ALTER TABLE harness_capacity_snapshots_legacy RENAME TO harness_capacity_snapshots")
    create index(:harness_capacity_snapshots, [:goal_id, :observed_at])
    create index(:harness_capacity_snapshots, [:run_id, :observed_at])
    create index(:harness_capacity_snapshots, [:compatibility_state, :support_tier])
  end
end
