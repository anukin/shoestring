defmodule Shoestring.Trajectory.WriterContentionTest do
  @moduledoc """
  The trajectory writer under REAL SQLite lock contention.

  ## The defect these lock (base `d3fa152`)

  Exqlite reports a busy step as `"Database busy"` (`Exqlite.Sqlite3` throws
  that string verbatim). `Writer.database_error/1` recognised only
  `"database is locked"`, `"database table is locked"` and `"SQLITE_BUSY"`, so
  the writer's bounded retry never fired and the first contended append was a
  permanent `{:database_error, "Database busy …"}`. Live, three of five
  `/runs/new` launches died that way before `run.starting`
  (`live-production-rerun.md` §3.3).

  Each LOCK test fails on base for that reason — the append returns
  `{:error, {:database_error, "Database busy" <> _}}` instead of retrying —
  not on a missing function. DOC tests pass on base and pin properties the
  fix must keep: non-busy errors are never retried, and retries are bounded.

  ## How contention is produced, without sleeps

  Every test runs against a real WAL-mode file database (the test sandbox
  wraps each test in one transaction, which hides the lock boundary). A raw
  `Exqlite.Sqlite3` connection holds SQLite's write lock with
  `BEGIN IMMEDIATE`. The writer's repo runs with `busy_timeout: 0`, so a
  contended statement fails at once instead of after a wall-clock wait. The
  lock is released from a `:telemetry` query handler, which runs
  synchronously in the writer process after its first failed statement — so
  "the lock clears between attempt 1 and attempt 2" is an ordering, not a
  timing.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Shoestring.Test.MigrationRepo
  alias Shoestring.Trajectory.{AppendInput, Goal, TrajectoryEvent, Writer}

  @migrations_path Path.join([File.cwd!(), "priv", "repo", "migrations"])
  @telemetry_event [:shoestring, :test, :migration_repo, :query]

  setup do
    dir =
      Path.join(System.tmp_dir!(), "shoestring-writer-busy-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    database = Path.join(dir, "writer.db")

    # Migrate on one connection with the normal busy timeout, as the release
    # task does, then reopen with the settings under test.
    start_supervised!(
      {MigrationRepo,
       [database: database, pool_size: 1, journal_mode: :wal, busy_timeout: 2_000, log: false]}
    )

    Ecto.Migrator.run(MigrationRepo, @migrations_path, :up, all: true, log: false)
    :ok = stop_supervised(MigrationRepo)

    start_supervised!(
      {MigrationRepo,
       [database: database, pool_size: 4, journal_mode: :wal, busy_timeout: 0, log: false]}
    )

    {:ok, holder} = Exqlite.Sqlite3.open(database)
    on_exit(fn -> Exqlite.Sqlite3.close(holder) end)

    {:ok, database: database, holder: holder}
  end

  test "LOCK: an append that meets a held write lock retries, and lands exactly once", %{
    holder: holder
  } do
    goal_id = insert_goal!()
    hold_write_lock!(holder)
    failures = release_after_first_failure(holder)

    pid = start_writer!(goal_id, max_retries: 2)

    assert {:ok, %TrajectoryEvent{sequence: 1} = event} =
             GenServer.call(pid, {:append, input("first", "k-first")})

    # It really was contended: exactly one statement failed, then it landed.
    assert :counters.get(failures, 1) == 1
    assert [%{id: id, sequence: 1}] = events(goal_id)
    assert id == event.id
  end

  test "LOCK: contention on a later append keeps sequences contiguous and events unique", %{
    holder: holder
  } do
    goal_id = insert_goal!()
    pid = start_writer!(goal_id, max_retries: 2)

    assert {:ok, %{sequence: 1}} = GenServer.call(pid, {:append, input("one", "k-1")})

    hold_write_lock!(holder)
    failures = release_after_first_failure(holder)

    assert {:ok, %{sequence: 2}} = GenServer.call(pid, {:append, input("two", "k-2")})
    assert :counters.get(failures, 1) == 1

    # The same idempotency key again, uncontended: the recorded event, not a
    # third row.
    assert {:ok, %{sequence: 2}} = GenServer.call(pid, {:append, input("two", "k-2")})
    assert Enum.map(events(goal_id), & &1.sequence) == [1, 2]
  end

  test "LOCK: exhausted contention is a bounded busy error and leaves nothing behind", %{
    holder: holder
  } do
    goal_id = insert_goal!()
    hold_write_lock!(holder)
    failures = count_failures()

    pid = start_writer!(goal_id, max_retries: 2)

    assert {:error, {:retry_exhausted, :busy}} =
             GenServer.call(pid, {:append, input("never", "k-never")})

    # One attempt plus exactly max_retries retries, each one a failed
    # statement against the held lock.
    assert :counters.get(failures, 1) == 3

    commit!(holder)
    assert events(goal_id) == []
  end

  test "LOCK: concurrent writers for different goals behind one held lock all land once", %{
    database: database,
    holder: holder
  } do
    # Four writers contend with the held lock AND with each other once it
    # clears. With `busy_timeout: 0` the second kind of contention fails at
    # once too, so bounded retries could legitimately run out (observed once,
    # under `--trace`). Production waits on SQLite's busy handler
    # (`busy_timeout: 2_000`, config/config.exs); so does this test. The first
    # writer to give up after that wait releases the held lock.
    :ok = stop_supervised(MigrationRepo)

    start_supervised!(
      {MigrationRepo,
       [database: database, pool_size: 4, journal_mode: :wal, busy_timeout: 2_000, log: false]}
    )

    goal_ids = for _ <- 1..4, do: insert_goal!()
    pids = Enum.map(goal_ids, &start_writer!(&1, max_retries: 2))

    hold_write_lock!(holder)

    # Four launches contend at once. The first failed statement (from any
    # writer) releases the lock; every writer that failed retries.
    failures = release_after_first_failure(holder)

    tasks =
      for {pid, n} <- Enum.with_index(pids) do
        Task.async(fn ->
          GenServer.call(pid, {:append, input("launch #{n}", "k-launch")}, 15_000)
        end)
      end

    results = Task.await_many(tasks, 15_000)

    assert Enum.all?(results, &match?({:ok, %TrajectoryEvent{sequence: 1}}, &1)),
           inspect(results)

    assert :counters.get(failures, 1) >= 1

    for goal_id <- goal_ids do
      assert [%{sequence: 1}] = events(goal_id)
    end
  end

  test "DOC: a non-busy database error is returned as-is and never retried" do
    goal_id = insert_goal!()
    attempts = :counters.new(1, [])

    attempt_fun = fn _input, _references, _state ->
      :counters.add(attempts, 1, 1)
      raise Exqlite.Error, message: "disk I/O error"
    end

    pid = start_writer!(goal_id, max_retries: 2, attempt_fun: attempt_fun)

    assert {:error, {:database_error, "disk I/O error"}} =
             GenServer.call(pid, {:append, input("io", "k-io")})

    assert :counters.get(attempts, 1) == 1
  end

  test "LOCK: Exqlite's own busy message is retryable wherever it is raised" do
    goal_id = insert_goal!()
    attempts = :counters.new(1, [])

    attempt_fun = fn _input, _references, _state ->
      :counters.add(attempts, 1, 1)
      raise Exqlite.Error, message: "Database busy\nINSERT INTO \"trajectory_events\" …"
    end

    pid = start_writer!(goal_id, max_retries: 2, attempt_fun: attempt_fun)

    assert {:error, {:retry_exhausted, :busy}} =
             GenServer.call(pid, {:append, input("busy", "k-busy")})

    assert :counters.get(attempts, 1) == 3
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  defp start_writer!(goal_id, opts) do
    start_supervised!(
      {Writer, [goal_id: goal_id, repo: MigrationRepo, idle_timeout: :infinity] ++ opts},
      id: {Writer, goal_id}
    )
  end

  defp insert_goal! do
    goal =
      %Goal{}
      |> Ecto.Changeset.change(%{
        id: Ecto.UUID.generate(),
        owner_id: Ecto.UUID.generate(),
        title: "Writer contention goal",
        status: "active"
      })
      |> MigrationRepo.insert!()

    goal.id
  end

  defp input(decision, key) do
    %AppendInput{
      type: "decision.recorded",
      schema_version: 1,
      actor: "system",
      payload: %{"decision" => decision},
      idempotency_key: key
    }
  end

  defp events(goal_id) do
    MigrationRepo.all(
      from event in TrajectoryEvent,
        where: event.goal_id == ^goal_id,
        order_by: [asc: event.sequence]
    )
  end

  defp hold_write_lock!(holder), do: :ok = Exqlite.Sqlite3.execute(holder, "BEGIN IMMEDIATE")
  defp commit!(holder), do: :ok = Exqlite.Sqlite3.execute(holder, "COMMIT")

  # Counts failed statements on the writer's repo; releases nothing.
  defp count_failures, do: attach(fn -> :ok end)

  # Releases the held lock once, synchronously, from inside the first failed
  # statement's telemetry — i.e. after attempt 1 failed and before attempt 2.
  defp release_after_first_failure(holder) do
    released = :atomics.new(1, [])

    attach(fn ->
      if :atomics.compare_exchange(released, 1, 0, 1) == :ok, do: commit!(holder)
    end)
  end

  defp attach(on_failure) do
    failures = :counters.new(1, [])
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      @telemetry_event,
      fn _event, _measurements, metadata, _config ->
        case metadata[:result] do
          {:error, _reason} ->
            :counters.add(failures, 1, 1)
            on_failure.()

          _ok ->
            :ok
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    failures
  end
end
