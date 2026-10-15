defmodule Shoestring.Harness.DispatchEffectSnapshotRegressionTest do
  @moduledoc """
  `Dispatches.complete_effect/2` and `record_effect_outcome/3` read the
  dispatch and then update it. In a deferred transaction under WAL, a writer
  committing between the read and the update makes the update fail at once
  with `Database busy`; the busy timeout never applies. With two concurrent
  Elves this lost the effect completion of a launched run, and the retried job
  recorded `dispatch.effect_unknown` instead.

  The tests run on an independent WAL database with real pooled connections
  (no SQL sandbox, which would turn the transaction into a savepoint). A
  telemetry hook commits a second writer right after the transaction's read.
  Databases are retained; no cleanup/reaper behaviour or provider calls.
  """
  use ExUnit.Case, async: false

  alias Shoestring.Harness.{DispatchRecord, Dispatches}
  alias Shoestring.Test.MigrationRepo
  alias Shoestring.Trajectory.TrajectoryEvent

  @now ~U[2026-10-15 06:00:00.000000Z]
  @handler "dispatch-effect-snapshot-race"

  @migrations [
    {20_260_830_012_112, Shoestring.Repo.Migrations.CreateTrajectoryFoundation},
    {20_260_830_023_603, Shoestring.Repo.Migrations.AddProjectorStatusAndFailureDetails},
    {20_260_831_050_006, Shoestring.Repo.Migrations.AddHarnessFoundation},
    {20_260_901_232_504, Shoestring.Repo.Migrations.AddObanDispatch}
  ]

  setup do
    directory = Path.join(System.tmp_dir!(), "shoestring-dispatch-race-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)

    repo_opts = [
      database: Path.join(directory, "dispatch.db"),
      pool_size: 4,
      journal_mode: :wal,
      busy_timeout: 5_000,
      foreign_keys: :off
    ]

    # Historical SQLite table rebuilds use connection-local PRAGMA switches.
    start_supervised!({MigrationRepo, Keyword.put(repo_opts, :pool_size, 1)})
    Ecto.Migrator.run(MigrationRepo, @migrations, :up, all: true, log: false)
    stop_supervised!(MigrationRepo)
    start_supervised!({MigrationRepo, repo_opts})

    on_exit(fn -> :telemetry.detach(@handler) end)
    :ok
  end

  defp dispatch!(status) do
    MigrationRepo.insert!(%DispatchRecord{
      dispatch_id: Ecto.UUID.generate(),
      goal_id: Ecto.UUID.generate(),
      task_id: Ecto.UUID.generate(),
      run_id: Ecto.UUID.generate(),
      request_version: 1,
      status: status
    })
  end

  # After this process first reads `harness_dispatches`, another connection
  # inserts a dispatch. It is given 300 ms: it commits at once while this
  # transaction holds no write lock, and waits for this commit otherwise.
  defp race_after_first_read! do
    test = self()

    :ok =
      :telemetry.attach(
        @handler,
        [:shoestring, :test, :migration_repo, :query],
        fn _event, _measures, meta, _config ->
          if self() == test and Process.get(:raced) == nil and
               String.starts_with?(meta.query, "SELECT") and
               String.contains?(meta.query, ~s("harness_dispatches")) do
            Process.put(:raced, true)
            writer = Task.async(fn -> dispatch!("requested") end)
            Process.put(:writer, {writer, Task.yield(writer, 300)})
          end
        end,
        nil
      )
  end

  defp writer_committed! do
    assert {writer, yielded} = Process.get(:writer)
    assert %DispatchRecord{} = if(yielded, do: elem(yielded, 1), else: Task.await(writer))
  end

  test "an effect completion survives a writer committing after its read" do
    dispatch = dispatch!("effect_started")
    race_after_first_read!()

    # The baseline raised Exqlite.Error "Database busy" here.
    assert :ok = Dispatches.complete_effect(dispatch.dispatch_id, repo: MigrationRepo)

    assert %DispatchRecord{status: "effect_completed"} =
             MigrationRepo.get!(DispatchRecord, dispatch.dispatch_id)

    writer_committed!()
  end

  test "an effect outcome survives a writer committing after its read" do
    dispatch = dispatch!("effect_started")

    # The outcome event already exists, so only the dispatch row is written.
    MigrationRepo.insert!(%TrajectoryEvent{
      goal_id: dispatch.goal_id,
      run_id: dispatch.run_id,
      sequence: 1,
      type: "dispatch.effect_unknown",
      actor: "harness",
      occurred_at: @now,
      schema_version: 1,
      payload: %{},
      idempotency_key: "dispatch-effect-unknown:#{dispatch.dispatch_id}"
    })

    race_after_first_read!()

    # The baseline raised Exqlite.Error "Database busy" here.
    assert :ok =
             Dispatches.record_effect_outcome(dispatch.dispatch_id, "effect_unknown",
               repo: MigrationRepo
             )

    assert %DispatchRecord{status: "effect_unknown"} =
             MigrationRepo.get!(DispatchRecord, dispatch.dispatch_id)

    writer_committed!()
  end
end
