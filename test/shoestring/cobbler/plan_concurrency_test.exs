defmodule Shoestring.Cobbler.PlanConcurrencyTest do
  @moduledoc "Feature tests using independent real SQLite connections, without sandbox serialization."
  use ExUnit.Case, async: false
  alias Shoestring.Cobbler.Plans
  alias Shoestring.Test.MigrationRepo
  alias Shoestring.Trajectory.TrajectoryEvent
  import Ecto.Query
  import Shoestring.Test.PlanHelpers

  setup do
    # Retain the scratch database locally; this task authorizes no cleanup.
    directory = Path.join(File.cwd!(), "tmp/plan-race-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    repo = MigrationRepo

    start_supervised!(
      {repo,
       database: Path.join(directory, "plans.db"),
       pool_size: 8,
       journal_mode: :wal,
       busy_timeout: 2000}
    )

    migrations = [
      {20_260_830_012_112, Shoestring.Repo.Migrations.CreateTrajectoryFoundation},
      {20_261_001_004_130, Shoestring.Repo.Migrations.CreateCobblerPlanProjection}
    ]

    Ecto.Migrator.run(repo, migrations, :up, all: true)
    owner = Ecto.UUID.generate()
    goal = Ecto.UUID.generate()
    opts = [repo: repo]
    assert {:ok, _} = Plans.create_goal(owner, goal, "create", goal_contract(), opts)
    %{owner: owner, goal: goal, opts: opts, repo: repo}
  end

  defp race(actions) do
    actions
    |> Task.async_stream(fn action -> action.() end, max_concurrency: 8, timeout: 10_000)
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp proposed(ctx) do
    assert {:ok, result} = Plans.propose(ctx.owner, ctx.goal, "propose", nil, plan(), ctx.opts)
    result.state["revisions"][result.event.id]
  end

  test "same concurrent request produces one event and one authority", ctx do
    revision = proposed(ctx)

    results =
      race(
        for _ <- 1..8,
            do: fn ->
              Plans.approve(
                ctx.owner,
                ctx.goal,
                "approve",
                revision["id"],
                revision["digest"],
                ctx.opts
              )
            end
      )

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert Enum.count(results, fn {:ok, r} -> not r.repeated? end) == 1
    ids = Enum.map(results, fn {:ok, r} -> r.event.id end)
    assert length(Enum.uniq(ids)) == 1
    assert ctx.repo.aggregate(TrajectoryEvent, :count) == 3
    assert {:ok, active} = Plans.active_authority(ctx.owner, ctx.goal, ctx.opts)
    assert active["id"] == revision["id"]
  end

  test "conflicting concurrent approval and rejection never double-decide", ctx do
    revision = proposed(ctx)

    results =
      race([
        fn ->
          Plans.approve(
            ctx.owner,
            ctx.goal,
            "approve",
            revision["id"],
            revision["digest"],
            ctx.opts
          )
        end,
        fn ->
          Plans.reject(
            ctx.owner,
            ctx.goal,
            "reject",
            revision["id"],
            revision["digest"],
            "No",
            ctx.opts
          )
        end
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :decision_conflict})) == 1
    assert ctx.repo.aggregate(TrajectoryEvent, :count) == 3
    assert {:ok, state} = Plans.read(ctx.owner, ctx.goal, ctx.opts)
    status = state["revisions"][revision["id"]]["status"]
    assert status in ["approved", "rejected"]
    assert state["active_revision"] == if(status == "approved", do: revision["id"], else: nil)
    assert {:ok, ^state} = Plans.rebuild(ctx.owner, ctx.goal, ctx.opts)
  end

  test "concurrent edits preserve approved state and optimistic base admits only one edit", ctx do
    first = proposed(ctx)

    assert {:ok, _} =
             Plans.approve(ctx.owner, ctx.goal, "approve", first["id"], first["digest"], ctx.opts)

    results =
      race(
        for n <- 1..8,
            do: fn ->
              Plans.propose(ctx.owner, ctx.goal, "edit-#{n}", first["id"], plan(), ctx.opts)
            end
      )

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :stale_revision_or_revision_budget})) == 7
    assert {:ok, active} = Plans.active_authority(ctx.owner, ctx.goal, ctx.opts)
    assert active["id"] == first["id"]
    assert ctx.repo.aggregate(TrajectoryEvent, :count) == 4
    assert {:ok, state} = Plans.read(ctx.owner, ctx.goal, ctx.opts)
    assert map_size(state["revisions"]) == 2
    assert {:ok, ^state} = Plans.rebuild(ctx.owner, ctx.goal, ctx.opts)

    assert ctx.repo.all(from e in TrajectoryEvent, order_by: e.sequence, select: e.sequence) == [
             1,
             2,
             3,
             4
           ]
  end

  test "concurrent goal creation is idempotent across real connections", ctx do
    goal = Ecto.UUID.generate()

    results =
      race(
        for _ <- 1..8,
            do: fn ->
              Plans.create_goal(ctx.owner, goal, "create", goal_contract(), ctx.opts)
            end
      )

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert Enum.count(results, fn {:ok, r} -> not r.repeated? end) == 1
    assert ctx.repo.aggregate(from(e in TrajectoryEvent, where: e.goal_id == ^goal), :count) == 1
  end

  test "a writer outside the local serializer returns bounded storage_busy without partial writes",
       ctx do
    supervisor = start_supervised!({Task.Supervisor, []})
    parent = self()

    holder =
      Task.Supervisor.async_nolink(supervisor, fn ->
        ctx.repo.transaction(
          fn ->
            send(parent, :write_lock_held)

            receive do
              :release -> :released
            after
              10_000 -> ctx.repo.rollback(:holder_timeout)
            end
          end,
          mode: :immediate
        )
      end)

    assert_receive :write_lock_held

    assert {:error, :storage_busy} =
             Plans.propose(ctx.owner, ctx.goal, "propose", nil, plan(), ctx.opts)

    send(holder.pid, :release)
    assert {:ok, :released} = Task.await(holder, 10_000)
    assert ctx.repo.aggregate(TrajectoryEvent, :count) == 1

    assert {:ok, %{state: state}} =
             Plans.propose(ctx.owner, ctx.goal, "propose", nil, plan(), ctx.opts)

    assert map_size(state["revisions"]) == 1
  end
end
