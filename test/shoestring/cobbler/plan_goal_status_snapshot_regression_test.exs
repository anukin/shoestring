defmodule Shoestring.Cobbler.PlanGoalStatusSnapshotRegressionTest do
  @moduledoc """
  `PlanGoalStatus.sync/2` reads the goal and its plan history and then updates
  the goal row: the same read-then-write shape as the dispatch functions in
  `DispatchEffectSnapshotRegressionTest`. In a deferred transaction under WAL,
  a writer committing between the read and the update makes the update fail at
  once with `Database busy`; the busy timeout never applies.

  An independent WAL database with real pooled connections (no SQL sandbox,
  which would turn the transaction into a savepoint). A telemetry hook commits
  a second writer right after the transaction's first read. Databases are
  retained; no cleanup/reaper behaviour or provider calls.
  """
  use ExUnit.Case, async: false

  alias Shoestring.Cobbler.PlanGoalStatus
  alias Shoestring.Test.MigrationRepo
  alias Shoestring.Trajectory.{Goal, TrajectoryEvent}

  @now ~U[2026-10-15 06:00:00.000000Z]
  @iso_now DateTime.to_iso8601(@now)
  @owner "00000000-0000-4000-8000-0000000000ff"
  @handler "plan-goal-status-snapshot-race"

  @migrations [
    {20_260_830_012_112, Shoestring.Repo.Migrations.CreateTrajectoryFoundation}
  ]

  setup do
    directory =
      Path.join(System.tmp_dir!(), "shoestring-goal-status-race-#{Ecto.UUID.generate()}")

    File.mkdir_p!(directory)

    start_supervised!(
      {MigrationRepo,
       database: Path.join(directory, "goals.db"),
       pool_size: 4,
       journal_mode: :wal,
       busy_timeout: 5_000}
    )

    Ecto.Migrator.run(MigrationRepo, @migrations, :up, all: true, log: false)
    on_exit(fn -> :telemetry.detach(@handler) end)
    :ok
  end

  defp goal!(status) do
    id = Ecto.UUID.generate()

    MigrationRepo.query!(
      "INSERT INTO goals (id, owner_id, title, status, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
      [id, @owner, "Goal status race", status, @iso_now, @iso_now]
    )

    id
  end

  # After this process first reads `goals`, another connection inserts a goal.
  # It is given 300 ms: it commits at once while this transaction holds no
  # write lock, and waits for this commit otherwise.
  defp race_after_first_read! do
    test = self()

    :ok =
      :telemetry.attach(
        @handler,
        [:shoestring, :test, :migration_repo, :query],
        fn _event, _measures, meta, _config ->
          if self() == test and Process.get(:raced) == nil and
               String.starts_with?(meta.query, "SELECT") and
               String.contains?(meta.query, ~s("goals")) do
            Process.put(:raced, true)
            writer = Task.async(fn -> goal!("active") end)
            Process.put(:writer, {writer, Task.yield(writer, 300)})
          end
        end,
        nil
      )
  end

  test "a goal status repair survives a writer committing after its read" do
    goal_id = goal!("active")

    MigrationRepo.insert!(%TrajectoryEvent{
      goal_id: goal_id,
      sequence: 1,
      type: "cobbler.plan.execution.completed",
      actor: "cobbler",
      occurred_at: @now,
      schema_version: 1,
      payload: %{"execution_id" => "execution-1"},
      idempotency_key: "plan-execution-completed:#{goal_id}"
    })

    race_after_first_read!()

    # The baseline raised Exqlite.Error "Database busy" here.
    assert {:ok, :updated} = PlanGoalStatus.sync(goal_id, repo: MigrationRepo)
    assert %Goal{status: "completed"} = MigrationRepo.get!(Goal, goal_id)

    assert {writer, yielded} = Process.get(:writer)
    assert is_binary(if(yielded, do: elem(yielded, 1), else: Task.await(writer)))
  end
end
