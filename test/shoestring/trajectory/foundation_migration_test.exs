defmodule Shoestring.Trajectory.FoundationMigrationTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.Harness.{CapacitySnapshotRecord, CapacityWindowRecord}
  alias Shoestring.Trajectory.EventRegistry

  @base_migration 20_260_831_050_006
  @capacity_migration 20_260_901_232_628
  @legacy_reason "legacy_capacity_contract_missing_provenance"
  @migrations [
    {20_260_830_012_112, Shoestring.Repo.Migrations.CreateTrajectoryFoundation},
    {20_260_830_023_603, Shoestring.Repo.Migrations.AddProjectorStatusAndFailureDetails},
    {20_260_831_050_006, Shoestring.Repo.Migrations.AddHarnessFoundation},
    {20_260_901_232_628, Shoestring.Repo.Migrations.EvolveCapacitySnapshotContractV2}
  ]

  test "the empty database migration creates the complete foundation" do
    assert foundation_tables() ==
             [
               "artifacts",
               "goals",
               "harness_capacity_snapshots",
               "harness_capacity_windows",
               "harness_checkpoint_artifact_references",
               "harness_checkpoints",
               "harness_execution_leases",
               "harness_runs",
               "projector_positions",
               "tasks",
               "trajectory_events"
             ]
  end

  test "sqlite concurrency settings are explicit and enabled" do
    assert Application.fetch_env!(:shoestring, Shoestring.Repo)[:journal_mode] == :wal
    assert Application.fetch_env!(:shoestring, Shoestring.Repo)[:busy_timeout] == 2_000
    assert {:ok, %{rows: [["wal"]]}} = Repo.query("PRAGMA journal_mode")
    assert {:ok, %{rows: [[2_000]]}} = Repo.query("PRAGMA busy_timeout")
  end

  test "foundation tables use foreign keys and the canonical event indexes" do
    assert {:ok, %{rows: [[1]]}} = Repo.query("PRAGMA foreign_keys")

    assert index_names("trajectory_events") == [
             "trajectory_events_goal_id_idempotency_key_index",
             "trajectory_events_goal_id_run_id_sequence_index",
             "trajectory_events_goal_id_sequence_index",
             "trajectory_events_parent_event_id_index",
             "trajectory_events_task_id_sequence_index"
           ]
  end

  test "projector positions persist status and visible failure detail" do
    assert {:ok, %{rows: rows}} = Repo.query("PRAGMA table_info(projector_positions)")
    assert Enum.map(rows, &Enum.at(&1, 1)) |> Enum.take(-2) == ["status", "error_detail"]
  end

  test "harness tables carry normalized constraints and query indexes" do
    assert column_names("harness_runs") |> Enum.member?("dispatch_id")
    assert column_names("harness_execution_leases") |> Enum.member?("deadline")
    assert column_names("harness_checkpoints") |> Enum.member?("stop_reason")
    assert column_names("harness_capacity_snapshots") |> Enum.member?("capacity_state")
    assert column_names("harness_capacity_snapshots") |> Enum.member?("capacity_state_v2")
    assert column_names("harness_capacity_snapshots") |> Enum.member?("observed_at_v2")
    assert column_names("harness_capacity_windows") |> Enum.member?("used_percent")
    assert column_names("harness_capacity_windows") |> Enum.member?("state_v2")

    assert index_names("harness_runs") == [
             "harness_runs_dispatch_id_index",
             "harness_runs_goal_id_status_index",
             "harness_runs_goal_id_task_id_index"
           ]

    assert index_names("harness_capacity_windows") == [
             "harness_capacity_windows_reset_at_index",
             "harness_capacity_windows_snapshot_id_kind_index"
           ]
  end

  test "sqlite enforces canonical harness constraints on invalid updates" do
    goal_id = "00000000-0000-4000-8000-000000000401"
    task_id = "00000000-0000-4000-8000-000000000402"
    run_id = "00000000-0000-4000-8000-000000000403"
    snapshot_id = "00000000-0000-4000-8000-000000000404"
    window_id = "00000000-0000-4000-8000-000000000405"
    now = "2026-08-30T12:00:00.000000Z"

    assert {:ok, _} =
             Repo.query(
               "INSERT INTO goals (id, owner_id, title, status, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
               [goal_id, "00000000-0000-4000-8000-000000000406", "Goal", "active", now, now]
             )

    assert {:ok, _} =
             Repo.query(
               "INSERT INTO tasks (id, goal_id, title, status, position, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
               [task_id, goal_id, "Task", "pending", 0, now, now]
             )

    assert {:ok, _} =
             Repo.query(
               "INSERT INTO harness_runs (id, goal_id, task_id, dispatch_id, provider_id, workspace_ref, request_version, prompt, policy, requested_capabilities, status, projection_sequence, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
               [
                 run_id,
                 goal_id,
                 task_id,
                 "00000000-0000-4000-8000-000000000407",
                 "test",
                 "workspace",
                 1,
                 "prompt",
                 "{}",
                 "{}",
                 "requested",
                 0,
                 now,
                 now
               ]
             )

    assert {:error, _} =
             Repo.query("UPDATE harness_runs SET status = 'unsafe' WHERE id = ?", [run_id])

    assert {:ok, _} =
             Repo.query(
               "INSERT INTO harness_capacity_snapshots (id, goal_id, run_id, contract_version, capacity_state, observed_at, source_adapter_id, source_method, scope, confidence, support_tier, compatibility_state, extensions, projection_sequence, inserted_at, updated_at, capacity_state_v2, observed_at_v2, freshness_max_age_seconds, source_provider_id, source_invocation_mode, source_event, reason) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
               [
                 snapshot_id,
                 goal_id,
                 run_id,
                 1,
                 "known",
                 now,
                 "test",
                 "probe",
                 "account",
                 "none",
                 "supported",
                 "compatible",
                 "{}",
                 1,
                 now,
                 now,
                 "unknown",
                 now,
                 300,
                 "legacy",
                 "unknown",
                 "none",
                 "legacy_capacity_contract_missing_provenance"
               ]
             )

    assert {:error, _} =
             Repo.query(
               "INSERT INTO harness_capacity_windows (id, snapshot_id, kind, state, used_percent, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
               [window_id, snapshot_id, "five_hour", "known", 101, now, now]
             )

    assert {:error, _} =
             Repo.query(
               "UPDATE harness_capacity_snapshots SET capacity_state_v2 = 'available' WHERE id = ?",
               [snapshot_id]
             )

    assert {:error, _} =
             Repo.query(
               "UPDATE harness_capacity_snapshots SET capacity_state_v2 = 'observed' WHERE id = ?",
               [snapshot_id]
             )

    assert {:error, _} =
             Repo.query(
               "UPDATE harness_capacity_snapshots SET reason = NULL WHERE id = ?",
               [snapshot_id]
             )

    assert {:error, _} =
             Repo.query(
               "UPDATE harness_capacity_snapshots SET capacity_state_v2 = 'refused', support_tier = 'unsupported' WHERE id = ?",
               [snapshot_id]
             )

    assert {:error, _} =
             Repo.query(
               "UPDATE harness_capacity_snapshots SET capacity_state = 'available' WHERE id = ?",
               [snapshot_id]
             )

    assert {:error, _} =
             Repo.query(
               "UPDATE harness_capacity_snapshots SET freshness_max_age_seconds = 0 WHERE id = ?",
               [snapshot_id]
             )

    assert {:error, _} =
             Repo.query(
               "UPDATE harness_capacity_snapshots SET source_event = 'unknown' WHERE id = ?",
               [snapshot_id]
             )

    snapshot = Repo.get!(CapacitySnapshotRecord, snapshot_id)

    assert {:error, changeset} =
             Repo.update(
               CapacitySnapshotRecord.changeset(snapshot, %{
                 "legacy_capacity_state" => "available"
               })
             )

    assert Map.has_key?(errors_on(changeset), :legacy_capacity_state)

    assert {:ok, _} =
             Repo.query(
               "INSERT INTO harness_capacity_windows (id, snapshot_id, kind, state, state_v2, used_percent, unknown_reason, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
               [window_id, snapshot_id, "five_hour", "known", "observed", 25, nil, now, now]
             )

    assert {:error, _} =
             Repo.query("UPDATE harness_capacity_windows SET state_v2 = 'known' WHERE id = ?", [
               window_id
             ])

    assert {:error, _} =
             Repo.query("UPDATE harness_capacity_windows SET state_v2 = 'unknown' WHERE id = ?", [
               window_id
             ])

    assert {:error, _} =
             Repo.query(
               "UPDATE harness_capacity_windows SET unknown_reason = 'contradiction' WHERE id = ?",
               [window_id]
             )

    assert {:error, _} =
             Repo.query(
               "UPDATE harness_capacity_windows SET used_percent = NULL WHERE id = ?",
               [window_id]
             )

    assert {:error, _} =
             Repo.query("UPDATE harness_capacity_windows SET state = 'observed' WHERE id = ?", [
               window_id
             ])

    window = Repo.get!(CapacityWindowRecord, window_id)

    assert {:error, changeset} =
             Repo.update(CapacityWindowRecord.changeset(window, %{"legacy_state" => "observed"}))

    assert Map.has_key?(errors_on(changeset), :legacy_state)
  end

  test "migration output matches the canonical fields produced by event rebuild" do
    state_dir =
      Path.join(System.tmp_dir!(), "shoestring-migration-#{System.unique_integer([:positive])}")

    File.mkdir_p!(state_dir)
    on_exit(fn -> File.rm_rf!(state_dir) end)

    start_supervised!(
      {Shoestring.Test.MigrationRepo,
       [
         database: Path.join(state_dir, "migration.db"),
         pool_size: 1,
         journal_mode: :wal,
         busy_timeout: 2_000
       ]}
    )

    assert is_list(
             Ecto.Migrator.run(Shoestring.Test.MigrationRepo, @migrations, :up,
               to: @base_migration
             )
           )

    goal_id = "00000000-0000-4000-8000-000000000501"
    run_id = "00000000-0000-4000-8000-000000000502"
    snapshot_id = "00000000-0000-4000-8000-000000000503"
    window_id = "00000000-0000-4000-8000-000000000504"
    future_snapshot_id = "00000000-0000-4000-8000-000000000507"
    future_window_id = "00000000-0000-4000-8000-000000000508"
    observed_at = "2026-08-30T12:00:00.123456Z"
    expires_at = nil
    event_at = "2026-08-30T12:00:00.000000Z"

    assert {:ok, _} =
             Shoestring.Test.MigrationRepo.query(
               "INSERT INTO goals (id, owner_id, title, status, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
               [
                 goal_id,
                 "00000000-0000-4000-8000-000000000505",
                 "Migration goal",
                 "active",
                 event_at,
                 event_at
               ]
             )

    assert {:ok, _} =
             Shoestring.Test.MigrationRepo.query(
               "INSERT INTO harness_runs (id, goal_id, dispatch_id, provider_id, workspace_ref, request_version, prompt, policy, requested_capabilities, status, projection_sequence, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
               [
                 run_id,
                 goal_id,
                 "00000000-0000-4000-8000-000000000506",
                 "legacy",
                 "workspace",
                 1,
                 "prompt",
                 "{}",
                 "{}",
                 "running",
                 1,
                 event_at,
                 event_at
               ]
             )

    assert {:ok, _} =
             Shoestring.Test.MigrationRepo.query(
               "INSERT INTO harness_capacity_snapshots (id, goal_id, run_id, contract_version, capacity_state, observed_at, expires_at, source_adapter_id, source_method, scope, confidence, support_tier, compatibility_state, extensions, projection_sequence, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
               [
                 future_snapshot_id,
                 goal_id,
                 run_id,
                 1,
                 "known",
                 "2026-08-30T12:00:01.123456Z",
                 "2026-08-30T12:05:01.123456Z",
                 "legacy.adapter",
                 "probe",
                 "account",
                 "high",
                 "supported",
                 "compatible",
                 "{}",
                 2,
                 event_at,
                 event_at
               ]
             )

    assert {:ok, _} =
             Shoestring.Test.MigrationRepo.query(
               "INSERT INTO harness_capacity_windows (id, snapshot_id, kind, state, used_percent, reset_at, unknown_reason, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
               [
                 future_window_id,
                 future_snapshot_id,
                 "five_hour",
                 "known",
                 25.0,
                 nil,
                 nil,
                 event_at,
                 event_at
               ]
             )

    assert {:ok, _} =
             Shoestring.Test.MigrationRepo.query(
               "INSERT INTO harness_capacity_snapshots (id, goal_id, run_id, contract_version, capacity_state, observed_at, expires_at, source_adapter_id, source_method, scope, confidence, support_tier, compatibility_state, extensions, projection_sequence, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
               [
                 snapshot_id,
                 goal_id,
                 run_id,
                 1,
                 "known",
                 observed_at,
                 expires_at,
                 "legacy.adapter",
                 "probe",
                 "account",
                 "none",
                 "supported",
                 "compatible",
                 "{}",
                 1,
                 observed_at,
                 observed_at
               ]
             )

    assert {:ok, _} =
             Shoestring.Test.MigrationRepo.query(
               "INSERT INTO harness_capacity_windows (id, snapshot_id, kind, state, used_percent, reset_at, unknown_reason, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
               [
                 window_id,
                 snapshot_id,
                 "five_hour",
                 "known",
                 25.0,
                 nil,
                 nil,
                 observed_at,
                 observed_at
               ]
             )

    assert is_list(
             Ecto.Migrator.run(Shoestring.Test.MigrationRepo, @migrations, :up,
               to: @capacity_migration
             )
           )

    {:ok, %{columns: snapshot_columns, rows: [snapshot_row]}} =
      Shoestring.Test.MigrationRepo.query(
        "SELECT contract_version, capacity_state_v2, observed_at_v2, expires_at, freshness_max_age_seconds, source_method, source_adapter_id, source_provider_id, source_invocation_mode, source_event, scope, confidence, support_tier, compatibility_state, reason, extensions FROM harness_capacity_snapshots WHERE id = ?",
        [snapshot_id]
      )

    migrated_snapshot =
      snapshot_row
      |> Enum.zip(snapshot_columns)
      |> Map.new(fn {value, column} ->
        {column, if(column == "extensions", do: Jason.decode!(value), else: value)}
      end)

    {:ok, %{rows: [window_row]}} =
      Shoestring.Test.MigrationRepo.query(
        "SELECT kind, state_v2, used_percent, reset_at, unknown_reason FROM harness_capacity_windows WHERE id = ?",
        [window_id]
      )

    [migrated_kind, migrated_state, migrated_used, migrated_reset, migrated_reason] = window_row

    legacy_payload = %{
      "snapshot_id" => snapshot_id,
      "contract_version" => 1,
      "capacity_state" => "known",
      "windows" => %{
        "items" => [%{"kind" => "five_hour", "state" => "known", "used_percent" => 25.0}]
      },
      "observed_at" => observed_at,
      "expires_at" => expires_at,
      "source" => %{"adapter_id" => "legacy.adapter", "method" => "probe"},
      "scope" => "account",
      "confidence" => "none",
      "support_tier" => "supported",
      "compatibility_state" => "compatible",
      "extensions" => %{}
    }

    assert {:ok, rebuilt} =
             EventRegistry.upcast("capacity.snapshot_observed", 1, legacy_payload,
               now: ~U[2026-08-30 12:00:00.123456Z]
             )

    assert migrated_snapshot == %{
             "contract_version" => 2,
             "capacity_state_v2" => rebuilt["capacity_state"],
             "observed_at_v2" => rebuilt["observed_at"],
             "expires_at" => rebuilt["expires_at"],
             "freshness_max_age_seconds" => rebuilt["freshness"]["max_age_seconds"],
             "source_method" => "none",
             "source_adapter_id" => rebuilt["source"]["adapter_id"],
             "source_provider_id" => rebuilt["source"]["provider_id"],
             "source_invocation_mode" => rebuilt["source"]["invocation_mode"],
             "source_event" => rebuilt["source"]["event"],
             "scope" => rebuilt["scope"],
             "confidence" => rebuilt["confidence"],
             "support_tier" => rebuilt["support_tier"],
             "compatibility_state" => rebuilt["compatibility_state"],
             "reason" => rebuilt["reason"],
             "extensions" => rebuilt["extensions"]
           }

    assert {migrated_kind, migrated_state, migrated_used, migrated_reset, migrated_reason} ==
             {"five_hour", "observed", 25.0, nil, nil}

    assert rebuilt["windows"]["items"] == [
             %{
               "kind" => "five_hour",
               "state" => "observed",
               "used_percent" => 25.0
             }
           ]

    {:ok, %{rows: [future_snapshot_row]}} =
      Shoestring.Test.MigrationRepo.query(
        "SELECT capacity_state_v2, confidence, reason FROM harness_capacity_snapshots WHERE id = ?",
        [future_snapshot_id]
      )

    assert future_snapshot_row == [
             "unknown",
             "none",
             "legacy_capacity_observation_after_event"
           ]

    {:ok, %{rows: [future_window_row]}} =
      Shoestring.Test.MigrationRepo.query(
        "SELECT state_v2, used_percent, unknown_reason FROM harness_capacity_windows WHERE id = ?",
        [future_window_id]
      )

    assert future_window_row == [
             "unknown",
             nil,
             "legacy_capacity_observation_after_event"
           ]

    assert @legacy_reason == migrated_snapshot["reason"]

    assert is_list(
             Ecto.Migrator.run(Shoestring.Test.MigrationRepo, @migrations, :down,
               to: @base_migration
             )
           )

    {:ok, %{rows: snapshot_columns_after_down}} =
      Shoestring.Test.MigrationRepo.query("PRAGMA table_info(harness_capacity_snapshots)")

    {:ok, %{rows: window_columns_after_down}} =
      Shoestring.Test.MigrationRepo.query("PRAGMA table_info(harness_capacity_windows)")

    refute Enum.any?(snapshot_columns_after_down, &(Enum.at(&1, 1) == "capacity_state_v2"))
    refute Enum.any?(snapshot_columns_after_down, &(Enum.at(&1, 1) == "reason"))
    refute Enum.any?(window_columns_after_down, &(Enum.at(&1, 1) == "state_v2"))
  end

  defp foundation_tables do
    {:ok, %{rows: rows}} =
      Repo.query(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'schema_%' ORDER BY name"
      )

    Enum.map(rows, &hd/1)
  end

  defp index_names(table) do
    {:ok, %{rows: rows}} = Repo.query("PRAGMA index_list(#{table})")

    rows
    |> Enum.map(&Enum.at(&1, 1))
    |> Enum.reject(&String.starts_with?(&1, "sqlite_autoindex_"))
    |> Enum.sort()
  end

  defp column_names(table) do
    {:ok, %{rows: rows}} = Repo.query("PRAGMA table_info(#{table})")
    Enum.map(rows, &Enum.at(&1, 1))
  end
end
