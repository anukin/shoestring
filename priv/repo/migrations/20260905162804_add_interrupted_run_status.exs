defmodule Shoestring.Repo.Migrations.AddInterruptedRunStatus do
  use Ecto.Migration

  # SQLite cannot modify a table CHECK constraint with ALTER TABLE, so
  # harness_runs is rebuilt in both directions to admit the `interrupted`
  # terminal status: a turn deliberately stopped at the safe boundary
  # (lease non-renewal or adapter-level stop) is neither a task failure nor
  # an explicit cancellation, and the projection must say so honestly.
  #
  # This migration is intentionally non-transactional because rebuilding a
  # referenced table in SQLite requires toggling the foreign_keys PRAGMA,
  # which SQLite ignores inside a transaction.
  @disable_ddl_transaction true

  def up do
    execute("PRAGMA foreign_keys = OFF")
    rebuild_up()
    execute("PRAGMA foreign_keys = ON")
    execute("PRAGMA foreign_key_check")
  end

  def down do
    execute("PRAGMA foreign_keys = OFF")
    rebuild_down()
    execute("PRAGMA foreign_keys = ON")
    execute("PRAGMA foreign_key_check")
  end

  defp rebuild_up do
    execute("""
    CREATE TABLE harness_runs_v2 (
      id BLOB NOT NULL PRIMARY KEY,
      goal_id BLOB NOT NULL REFERENCES goals(id) ON DELETE CASCADE,
      task_id BLOB REFERENCES tasks(id) ON DELETE SET NULL,
      dispatch_id BLOB NOT NULL,
      provider_id TEXT NOT NULL,
      workspace_ref TEXT NOT NULL,
      request_version INTEGER NOT NULL
        CONSTRAINT harness_runs_request_version_positive
        CHECK (request_version > 0),
      prompt TEXT NOT NULL,
      continuation BLOB,
      policy BLOB NOT NULL,
      requested_capabilities BLOB NOT NULL,
      extensions BLOB NOT NULL DEFAULT '{}',
      status TEXT NOT NULL DEFAULT 'requested'
        CONSTRAINT harness_runs_status_valid
        CHECK (status IN ('requested', 'starting', 'running', 'pausing', 'suspended', 'completed', 'failed', 'interrupted', 'cancelling', 'cancelled')),
      provider_session_id TEXT,
      projection_sequence INTEGER NOT NULL DEFAULT 0
        CONSTRAINT harness_runs_projection_sequence_nonnegative
        CHECK (projection_sequence >= 0),
      inserted_at DATETIME NOT NULL,
      updated_at DATETIME NOT NULL
    )
    """)

    execute("""
    INSERT INTO harness_runs_v2
      (id, goal_id, task_id, dispatch_id, provider_id, workspace_ref,
       request_version, prompt, continuation, policy, requested_capabilities,
       extensions, status, provider_session_id, projection_sequence,
       inserted_at, updated_at)
    SELECT
      id, goal_id, task_id, dispatch_id, provider_id, workspace_ref,
      request_version, prompt, continuation, policy, requested_capabilities,
      extensions, status, provider_session_id, projection_sequence,
      inserted_at, updated_at
    FROM harness_runs
    """)

    execute("DROP TABLE harness_runs")
    execute("ALTER TABLE harness_runs_v2 RENAME TO harness_runs")
    create unique_index(:harness_runs, [:dispatch_id])
    create index(:harness_runs, [:goal_id, :status])
    create index(:harness_runs, [:goal_id, :task_id])
  end

  defp rebuild_down do
    execute("""
    CREATE TABLE harness_runs_legacy (
      id BLOB NOT NULL PRIMARY KEY,
      goal_id BLOB NOT NULL REFERENCES goals(id) ON DELETE CASCADE,
      task_id BLOB REFERENCES tasks(id) ON DELETE SET NULL,
      dispatch_id BLOB NOT NULL,
      provider_id TEXT NOT NULL,
      workspace_ref TEXT NOT NULL,
      request_version INTEGER NOT NULL
        CONSTRAINT harness_runs_request_version_positive
        CHECK (request_version > 0),
      prompt TEXT NOT NULL,
      continuation BLOB,
      policy BLOB NOT NULL,
      requested_capabilities BLOB NOT NULL,
      extensions BLOB NOT NULL DEFAULT '{}',
      status TEXT NOT NULL DEFAULT 'requested'
        CONSTRAINT harness_runs_status_valid
        CHECK (status IN ('requested', 'starting', 'running', 'pausing', 'suspended', 'completed', 'failed', 'cancelling', 'cancelled')),
      provider_session_id TEXT,
      projection_sequence INTEGER NOT NULL DEFAULT 0
        CONSTRAINT harness_runs_projection_sequence_nonnegative
        CHECK (projection_sequence >= 0),
      inserted_at DATETIME NOT NULL,
      updated_at DATETIME NOT NULL
    )
    """)

    execute("""
    INSERT INTO harness_runs_legacy
      (id, goal_id, task_id, dispatch_id, provider_id, workspace_ref,
       request_version, prompt, continuation, policy, requested_capabilities,
       extensions, status, provider_session_id, projection_sequence,
       inserted_at, updated_at)
    SELECT
      id, goal_id, task_id, dispatch_id, provider_id, workspace_ref,
      request_version, prompt, continuation, policy, requested_capabilities,
      extensions,
      CASE WHEN status = 'interrupted' THEN 'cancelled' ELSE status END,
      provider_session_id, projection_sequence,
      inserted_at, updated_at
    FROM harness_runs
    """)

    execute("DROP TABLE harness_runs")
    execute("ALTER TABLE harness_runs_legacy RENAME TO harness_runs")
    create unique_index(:harness_runs, [:dispatch_id])
    create index(:harness_runs, [:goal_id, :status])
    create index(:harness_runs, [:goal_id, :task_id])
  end
end
