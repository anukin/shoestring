defmodule Shoestring.Harness.ObservatoryMigrationTest do
  use ExUnit.Case, async: false

  alias Shoestring.Harness.Observatory

  @migrations [
    {20_260_830_012_112, Shoestring.Repo.Migrations.CreateTrajectoryFoundation},
    {20_260_830_023_603, Shoestring.Repo.Migrations.AddProjectorStatusAndFailureDetails},
    {20_260_831_050_006, Shoestring.Repo.Migrations.AddHarnessFoundation},
    {20_260_901_232_628, Shoestring.Repo.Migrations.EvolveCapacitySnapshotContractV2},
    {20_260_903_000_650, Shoestring.Repo.Migrations.HardenCapacitySnapshotContractV2},
    {20_260_903_054_508, Shoestring.Repo.Migrations.CreateCapacityObservatorySingleton}
  ]

  @observatory_migration 20_260_903_054_508

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

  test "migration up from clean database provisions observatory singleton and triggers", %{
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

    # 4. Migration down drops triggers and cleans up singleton goal
    assert [@observatory_migration] ==
             Ecto.Migrator.run(repo, @migrations, :down, step: 1)

    assert {:ok, %{rows: []}} =
             repo.query("SELECT id FROM goals WHERE id = ?", [goal_id])

    # 5. Migration up is re-runnable and idempotent
    assert [@observatory_migration] ==
             Ecto.Migrator.run(repo, @migrations, :up, step: 1)

    assert {:ok, %{rows: [[^goal_id, ^owner_id, ^title, ^status]]}} =
             repo.query(
               "SELECT id, owner_id, title, status FROM goals WHERE id = ?",
               [goal_id]
             )
  end
end
