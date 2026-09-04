defmodule Shoestring.Harness.ObservatoryMigrationTest do
  use ExUnit.Case, async: false

  alias Shoestring.Harness.Observatory
  alias Shoestring.Trajectory.Goal

  @migrations [
    {20_260_830_012_112, Shoestring.Repo.Migrations.CreateTrajectoryFoundation},
    {20_260_830_023_603, Shoestring.Repo.Migrations.AddProjectorStatusAndFailureDetails},
    {20_260_831_050_006, Shoestring.Repo.Migrations.AddHarnessFoundation},
    {20_260_901_232_628, Shoestring.Repo.Migrations.EvolveCapacitySnapshotContractV2},
    {20_260_903_000_650, Shoestring.Repo.Migrations.HardenCapacitySnapshotContractV2},
    {20_260_903_054_508, Shoestring.Repo.Migrations.CreateCapacityObservatorySingleton},
    {20_260_903_061_948, Shoestring.Repo.Migrations.AddCapacityObservatoryLookupIndex},
    {20_260_903_231_739, Shoestring.Repo.Migrations.RepairCapacityObservatorySingletonTriggers}
  ]

  @observatory_migration 20_260_903_054_508
  @index_migration 20_260_903_061_948
  @repair_migration 20_260_903_231_739

  setup do
    state_dir =
      Path.join(
        System.tmp_dir!(),
        "shoestring-obs-migration-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(state_dir)
    db_path = Path.join(state_dir, "migration_test.db")

    on_exit(fn ->
      File.rm_rf!(state_dir)
    end)

    start_supervised!(
      {Shoestring.Test.MigrationRepo,
       [
         database: db_path,
         pool_size: 1,
         journal_mode: :wal,
         busy_timeout: 2_000
       ]}
    )

    %{repo: Shoestring.Test.MigrationRepo}
  end

  test "migration up from clean database provisions observatory singleton and triggers, and clean down succeeds",
       %{
         repo: repo
       } do
    assert is_list(Ecto.Migrator.run(repo, @migrations, :up, all: true))

    # 1. Observatory singleton goal is provisioned with expected attributes
    goal_id = Observatory.observatory_goal_id()
    owner_id = Observatory.observatory_owner_id()

    assert {:ok, %{rows: [[^goal_id, ^owner_id, title, status]]}} =
             repo.query(
               "SELECT id, owner_id, title, status FROM goals WHERE id = ?",
               [goal_id]
             )

    assert title == Observatory.observatory_title()
    assert status == Observatory.observatory_status()

    # 2. Database triggers prevent ordinary UPDATE and DELETE on the observatory singleton
    assert {:error, %Exqlite.Error{message: message}} =
             repo.query("UPDATE goals SET title = 'tampered' WHERE id = ?", [goal_id])

    assert String.contains?(message, "protected observatory goal cannot be updated")

    assert {:error, %Exqlite.Error{message: message}} =
             repo.query("DELETE FROM goals WHERE id = ?", [goal_id])

    assert String.contains?(message, "protected observatory goal cannot be deleted")

    # 3. Ordinary goals are untouched and can be updated and deleted normally
    user_goal_id = "00000000-0000-4000-8000-000000000991"
    user_owner_id = "00000000-0000-4000-8000-000000000992"
    now = DateTime.to_iso8601(DateTime.utc_now())

    assert {:ok, _} =
             repo.query(
               "INSERT INTO goals (id, owner_id, title, status, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
               [user_goal_id, user_owner_id, "User Goal", "active", now, now]
             )

    assert {:ok, _} =
             repo.query("UPDATE goals SET title = 'User Goal Updated' WHERE id = ?", [
               user_goal_id
             ])

    assert {:ok, %{rows: [["User Goal Updated"]]}} =
             repo.query("SELECT title FROM goals WHERE id = ?", [user_goal_id])

    assert {:ok, _} = repo.query("DELETE FROM goals WHERE id = ?", [user_goal_id])

    assert_identity_qualified_triggers(repo)

    # 4. Clean migration down drops the repair, index, triggers, and singleton goal
    assert [@repair_migration, @index_migration, @observatory_migration] ==
             Ecto.Migrator.run(repo, @migrations, :down, step: 3)

    assert {:ok, %{rows: []}} =
             repo.query("SELECT id FROM goals WHERE id = ?", [goal_id])

    # 5. Migration up is re-runnable and idempotent
    assert [@observatory_migration, @index_migration, @repair_migration] ==
             Ecto.Migrator.run(repo, @migrations, :up, step: 3)

    assert {:ok, %{rows: [[^goal_id, ^owner_id, ^title, ^status]]}} =
             repo.query(
               "SELECT id, owner_id, title, status FROM goals WHERE id = ?",
               [goal_id]
             )
  end

  test "upgrade from the old migration tightens triggers and removes only invalid cross-goal lease projections",
       %{
         repo: repo
       } do
    old_migrations = Enum.take(@migrations, 6)
    assert is_list(Ecto.Migrator.run(repo, old_migrations, :up, all: true))

    old_update_trigger = trigger_sql(repo, "protect_observatory_goal_update")
    refute String.contains?(old_update_trigger, "OLD.owner_id")
    refute String.contains?(old_update_trigger, "OLD.status")

    {invalid_lease_id, valid_lease_id, valid_snapshot_id} =
      insert_representative_lease_projections(repo)

    assert [@repair_migration] == Ecto.Migrator.run(repo, repair_migration(), :up, all: true)

    assert_identity_qualified_triggers(repo)

    observatory_goal = fetch_goal(repo, Observatory.observatory_goal_id())
    assert Goal.observatory?(observatory_goal)
    refute Goal.changeset(observatory_goal, %{"title" => "Tampered"}).valid?

    assert {:error, %Exqlite.Error{message: message}} =
             repo.query("UPDATE goals SET title = 'tampered' WHERE id = ?", [
               observatory_goal.id
             ])

    assert String.contains?(message, "protected observatory goal cannot be updated")

    assert {:ok, %{rows: []}} =
             repo.query("SELECT id FROM harness_execution_leases WHERE id = ?", [
               invalid_lease_id
             ])

    assert {:ok, %{rows: [[^valid_lease_id, ^valid_snapshot_id]]}} =
             repo.query(
               "SELECT id, admitted_snapshot_id FROM harness_execution_leases WHERE id = ?",
               [valid_lease_id]
             )
  end

  test "upgrade preserves and unlocks a victim row while protecting a future genuine singleton",
       %{
         repo: repo
       } do
    pre_observatory_migrations = Enum.take(@migrations, 5)

    assert is_list(Ecto.Migrator.run(repo, pre_observatory_migrations, :up, all: true))

    reserved_id = Observatory.observatory_goal_id()
    victim_owner_id = "00000000-0000-4000-8000-000000000777"
    now = DateTime.to_iso8601(DateTime.utc_now())

    assert {:ok, _} =
             repo.query(
               "INSERT INTO goals (id, owner_id, title, status, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
               [reserved_id, victim_owner_id, "Victim User Goal", "active", now, now]
             )

    # The already-released migration keeps the victim through INSERT OR IGNORE,
    # records its version as applied, and installs coarse id-only triggers.
    assert [@observatory_migration] ==
             Ecto.Migrator.run(repo, old_observatory_migration(), :up, all: true)

    assert {:ok, %{rows: [[^reserved_id, ^victim_owner_id, "Victim User Goal", "active"]]}} =
             repo.query("SELECT id, owner_id, title, status FROM goals WHERE id = ?", [
               reserved_id
             ])

    victim_goal = fetch_goal(repo, reserved_id)
    refute Goal.observatory?(victim_goal)
    assert Goal.changeset(victim_goal, %{"title" => "Victim Renamed"}).valid?

    assert {:error, %Exqlite.Error{message: message}} =
             repo.query("UPDATE goals SET title = 'Victim Renamed' WHERE id = ?", [reserved_id])

    assert String.contains?(message, "protected observatory goal cannot be updated")

    assert [@repair_migration] == Ecto.Migrator.run(repo, repair_migration(), :up, all: true)
    assert_identity_qualified_triggers(repo)

    assert {:ok, _} =
             repo.query("UPDATE goals SET title = 'Victim Renamed' WHERE id = ?", [reserved_id])

    assert {:ok, _} = repo.query("DELETE FROM goals WHERE id = ?", [reserved_id])

    insert_genuine_observatory_goal(repo, now)

    genuine_goal = fetch_goal(repo, reserved_id)
    assert Goal.observatory?(genuine_goal)
    refute Goal.changeset(genuine_goal, %{"title" => "Tampered"}).valid?

    assert {:error, %Exqlite.Error{message: message}} =
             repo.query("UPDATE goals SET title = 'tampered' WHERE id = ?", [reserved_id])

    assert String.contains?(message, "protected observatory goal cannot be updated")

    assert {:error, %Exqlite.Error{message: message}} =
             repo.query("DELETE FROM goals WHERE id = ?", [reserved_id])

    assert String.contains?(message, "protected observatory goal cannot be deleted")
  end

  test "migration down refuses rollback when ledger data exists, preventing partial data destruction",
       %{
         repo: repo
       } do
    assert is_list(Ecto.Migrator.run(repo, @migrations, :up, all: true))

    goal_id = Observatory.observatory_goal_id()
    now = DateTime.to_iso8601(DateTime.utc_now())
    event_id = "00000000-0000-4000-8000-000000000e01"

    # Insert a trajectory event for the observatory goal
    assert {:ok, _} =
             repo.query(
               """
               INSERT INTO trajectory_events
                 (id, goal_id, sequence, type, actor, occurred_at, schema_version, payload, idempotency_key)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
               """,
               [
                 event_id,
                 goal_id,
                 1,
                 "capacity.snapshot_observed",
                 "test",
                 now,
                 2,
                 "{}",
                 "test-event-1"
               ]
             )

    assert_raise RuntimeError, ~r/refusing rollback to prevent data destruction/i, fn ->
      Ecto.Migrator.run(repo, @migrations, :down, step: 1)
    end

    # Verify the observatory singleton goal and protection triggers are still intact
    assert {:ok, %{rows: [[^goal_id]]}} =
             repo.query("SELECT id FROM goals WHERE id = ?", [goal_id])

    assert {:error, %Exqlite.Error{message: message}} =
             repo.query("DELETE FROM goals WHERE id = ?", [goal_id])

    assert String.contains?(message, "protected observatory goal cannot be deleted")

    # The original singleton migration refuses destructive rollback as well when
    # targeted directly: this fails if its guard is ever reverted to a silent delete.
    assert_raise RuntimeError, ~r/refusing rollback to prevent data destruction/i, fn ->
      Ecto.Migrator.run(repo, old_observatory_migration(), :down, all: true)
    end

    # The refused rollback left the singleton goal intact
    assert {:ok, %{rows: [[^goal_id]]}} =
             repo.query("SELECT id FROM goals WHERE id = ?", [goal_id])

    # Clean up the event to allow clean rollback
    assert {:ok, _} = repo.query("DELETE FROM trajectory_events WHERE id = ?", [event_id])

    # Now the repair, index, and original migration can roll back safely.
    assert [@repair_migration, @index_migration, @observatory_migration] ==
             Ecto.Migrator.run(repo, @migrations, :down, step: 3)

    assert {:ok, %{rows: []}} =
             repo.query("SELECT id FROM goals WHERE id = ?", [goal_id])
  end

  defp old_observatory_migration, do: [Enum.at(@migrations, 5)]
  defp repair_migration, do: [List.last(@migrations)]

  defp trigger_sql(repo, name) do
    assert {:ok, %{rows: [[sql]]}} =
             repo.query("SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = ?", [
               name
             ])

    sql
  end

  defp assert_identity_qualified_triggers(repo) do
    for name <- ["protect_observatory_goal_delete", "protect_observatory_goal_update"] do
      sql = trigger_sql(repo, name)
      assert String.contains?(sql, "OLD.id = '#{Observatory.observatory_goal_id()}'")
      assert String.contains?(sql, "OLD.owner_id = '#{Observatory.observatory_owner_id()}'")
      assert String.contains?(sql, "OLD.status = '#{Observatory.observatory_status()}'")
      refute String.contains?(sql, "OLD.title")
      refute String.contains?(sql, "OLD.description")
    end
  end

  defp fetch_goal(repo, id) do
    assert {:ok, %{rows: [[^id, owner_id, title, description, status]]}} =
             repo.query(
               "SELECT id, owner_id, title, description, status FROM goals WHERE id = ?",
               [id]
             )

    %Goal{
      id: id,
      owner_id: owner_id,
      title: title,
      description: description,
      status: status
    }
    |> Ecto.put_meta(state: :loaded)
  end

  defp insert_genuine_observatory_goal(repo, now) do
    assert {:ok, _} =
             repo.query(
               """
               INSERT INTO goals
                 (id, owner_id, title, description, status, inserted_at, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?)
               """,
               [
                 Observatory.observatory_goal_id(),
                 Observatory.observatory_owner_id(),
                 Observatory.observatory_title(),
                 Observatory.observatory_description(),
                 Observatory.observatory_status(),
                 now,
                 now
               ]
             )
  end

  defp insert_representative_lease_projections(repo) do
    user_goal_id = "00000000-0000-4000-8000-000000000a01"
    user_owner_id = "00000000-0000-4000-8000-000000000a02"
    run_id = "00000000-0000-4000-8000-000000000a03"
    observatory_snapshot_id = "00000000-0000-4000-8000-000000000a04"
    user_snapshot_id = "00000000-0000-4000-8000-000000000a05"
    invalid_lease_id = "00000000-0000-4000-8000-000000000a06"
    valid_lease_id = "00000000-0000-4000-8000-000000000a07"
    now = "2026-09-03T00:00:00.000000Z"

    assert {:ok, _} =
             repo.query(
               "INSERT INTO goals (id, owner_id, title, status, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
               [user_goal_id, user_owner_id, "User Goal", "active", now, now]
             )

    assert {:ok, _} =
             repo.query(
               """
               INSERT INTO harness_runs
                 (id, goal_id, dispatch_id, provider_id, workspace_ref, request_version,
                  prompt, policy, requested_capabilities, status, projection_sequence,
                  inserted_at, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
               """,
               [
                 run_id,
                 user_goal_id,
                 "migration-upgrade-dispatch",
                 "codex",
                 "migration-test",
                 1,
                 "upgrade test",
                 "{}",
                 "{}",
                 "requested",
                 0,
                 now,
                 now
               ]
             )

    insert_capacity_snapshot(
      repo,
      observatory_snapshot_id,
      Observatory.observatory_goal_id(),
      now
    )

    insert_capacity_snapshot(repo, user_snapshot_id, user_goal_id, now)

    insert_execution_lease(
      repo,
      invalid_lease_id,
      user_goal_id,
      run_id,
      observatory_snapshot_id,
      now
    )

    insert_execution_lease(repo, valid_lease_id, user_goal_id, run_id, user_snapshot_id, now)

    {invalid_lease_id, valid_lease_id, user_snapshot_id}
  end

  defp insert_capacity_snapshot(repo, id, goal_id, now) do
    assert {:ok, _} =
             repo.query(
               """
               INSERT INTO harness_capacity_snapshots
                 (id, goal_id, contract_version, capacity_state, observed_at,
                  source_adapter_id, source_method, scope, confidence, support_tier,
                  compatibility_state, extensions, projection_sequence, inserted_at,
                  updated_at, capacity_state_v2, observed_at_v2,
                  freshness_max_age_seconds, source_provider_id, source_invocation_mode,
                  source_event, reason)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
               """,
               [
                 id,
                 goal_id,
                 2,
                 "unknown",
                 now,
                 "migration.fixture",
                 "none",
                 "migration-test",
                 "none",
                 "conservative_partial",
                 "degraded",
                 "{}",
                 1,
                 now,
                 now,
                 "unknown",
                 now,
                 300,
                 "codex",
                 "app_server",
                 "none",
                 "migration_upgrade_fixture"
               ]
             )
  end

  defp insert_execution_lease(repo, id, goal_id, run_id, snapshot_id, now) do
    assert {:ok, _} =
             repo.query(
               """
               INSERT INTO harness_execution_leases
                 (id, goal_id, run_id, admitted_snapshot_id, contract_version,
                  response_reserve, tool_reserve, response_budget, tool_budget,
                  deadline, checkpoint_cadence, renewal_state, status, extensions,
                  projection_sequence, inserted_at, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
               """,
               [
                 id,
                 goal_id,
                 run_id,
                 snapshot_id,
                 1,
                 10,
                 5,
                 100,
                 50,
                 now,
                 30,
                 "none",
                 "proposed",
                 "{}",
                 1,
                 now,
                 now
               ]
             )
  end
end
