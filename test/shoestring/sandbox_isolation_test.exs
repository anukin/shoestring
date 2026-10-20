defmodule Shoestring.SandboxIsolationTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Shoestring.Test.MigrationRepo

  test "a new sandbox cannot overtake the preceding SQLite rollback" do
    directory = Path.join(System.tmp_dir!(), "shoestring-sandbox-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)

    start_supervised!(
      {MigrationRepo,
       database: Path.join(directory, "fixture.db"),
       pool: Sandbox,
       pool_size: Application.fetch_env!(:shoestring, Shoestring.Repo)[:pool_size],
       busy_timeout: 0}
    )

    tasks = start_supervised!({Task.Supervisor, name: nil})
    MigrationRepo.query!("CREATE TABLE fixture_settings (id INTEGER PRIMARY KEY, value INTEGER)")
    MigrationRepo.query!("INSERT INTO fixture_settings VALUES (1, 0)")
    :ok = Sandbox.mode(MigrationRepo, :manual)
    owner = Sandbox.start_owner!(MigrationRepo, shared: false)
    MigrationRepo.query!("UPDATE fixture_settings SET value = 1 WHERE id = 1")

    %{pid: pool} = Ecto.Adapter.lookup_meta(MigrationRepo)

    [%{source: {:proxy, proxy}}] =
      Enum.filter(DBConnection.get_connection_metrics(pool), fn metric ->
        match?(%{source: {:proxy, _}}, metric)
      end)

    ref = Process.monitor(proxy)
    :ok = :sys.suspend(proxy)

    try do
      # Owner exit does not wait for its connection proxy to roll back.
      :ok = Sandbox.stop_owner(owner)

      checkout =
        Task.Supervisor.async_nolink(tasks, fn ->
          try do
            DBConnection.Ownership.ownership_checkout(pool, queue: false)
          rescue
            error in DBConnection.ConnectionError -> {:blocked, error.message}
          end
        end)

      assert {:blocked, message} = Task.await(checkout)
      assert message =~ "connection not available and queuing is disabled"
    after
      :ok = :sys.resume(proxy)
    end

    assert_receive {:DOWN, ^ref, :process, ^proxy, _reason}, 1_000

    successor =
      Task.Supervisor.async_nolink(tasks, fn ->
        :ok = Sandbox.checkout(MigrationRepo)

        try do
          assert %{rows: [[0]]} = MigrationRepo.query!("SELECT value FROM fixture_settings")
          MigrationRepo.query!("UPDATE fixture_settings SET value = 2 WHERE id = 1")
          assert %{rows: [[2]]} = MigrationRepo.query!("SELECT value FROM fixture_settings")
        after
          :ok = Sandbox.checkin(MigrationRepo)
        end
      end)

    _ = Task.await(successor)
  end
end
