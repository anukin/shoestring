defmodule Shoestring.Release.BackupTest do
  use ExUnit.Case, async: false
  alias Shoestring.Test.MigrationRepo, as: Repo
  @moduletag :tmp_dir

  test "consistent upgrade backup retains canonical history and leaves the source unchanged", %{
    tmp_dir: root
  } do
    source = Path.join(root, "shoestring.db")
    previous_state = System.get_env("SHOESTRING_TEST_STATE_DIR")
    previous_repos = Application.fetch_env!(:shoestring, :ecto_repos)
    previous_config = Application.fetch_env!(:shoestring, Shoestring.Repo)
    System.put_env("SHOESTRING_TEST_STATE_DIR", root)
    Application.put_env(:shoestring, :ecto_repos, [Repo])

    on_exit(fn ->
      if previous_state,
        do: System.put_env("SHOESTRING_TEST_STATE_DIR", previous_state),
        else: System.delete_env("SHOESTRING_TEST_STATE_DIR")

      Application.put_env(:shoestring, :ecto_repos, previous_repos)
      Application.put_env(:shoestring, Shoestring.Repo, previous_config)
    end)

    start_supervised!({Repo, database: source, pool_size: 1, journal_mode: :wal})
    migrations = Application.app_dir(:shoestring, "priv/repo/migrations")
    Ecto.Migrator.run(Repo, migrations, :up, to: 20_261_017_013_658, log: false)

    goal =
      Repo.insert!(%Shoestring.Trajectory.Goal{
        id: Ecto.UUID.generate(),
        owner_id: Ecto.UUID.generate(),
        title: "Synthetic upgrade",
        status: "open"
      })

    Repo.insert!(%Shoestring.Trajectory.TrajectoryEvent{
      id: Ecto.UUID.generate(),
      goal_id: goal.id,
      sequence: 1,
      type: "goal.created",
      actor: "fixture",
      occurred_at: ~U[2026-10-20 12:00:00.000000Z],
      schema_version: 1,
      payload: %{"title" => "Synthetic upgrade"}
    })

    before = Repo.query!("SELECT id, owner_id, status, title FROM goals").rows

    events_before =
      Repo.query!("SELECT id, goal_id, sequence, type, payload FROM trajectory_events").rows

    assert :ok = Shoestring.Release.migrate()
    [name] = File.ls!(Path.join(root, "backups"))
    backup = Path.join([root, "backups", name])
    assert Bitwise.band(File.stat!(backup).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(Path.dirname(backup)).mode, 0o777) == 0o700
    assert :ok = Shoestring.Release.migrate()
    assert File.ls!(Path.join(root, "backups")) == [name]
    assert Repo.query!("SELECT id, owner_id, status, title FROM goals").rows == before

    assert Repo.query!("SELECT id, goal_id, sequence, type, payload FROM trajectory_events").rows ==
             events_before

    assert Repo.query!("SELECT name FROM sqlite_master WHERE name = 'api_spend_reservations'").rows !=
             []

    stop_supervised!(Repo)
    start_supervised!({Repo, database: backup, pool_size: 1})
    assert Repo.query!("PRAGMA integrity_check").rows == [["ok"]]
    assert Repo.query!("SELECT id, owner_id, status, title FROM goals").rows == before

    assert Repo.query!("SELECT id, goal_id, sequence, type, payload FROM trajectory_events").rows ==
             events_before

    assert Repo.query!("SELECT name FROM sqlite_master WHERE name = 'api_spend_reservations'").rows ==
             []
  end
end
