defmodule Shoestring.Cobbler.PlanFinalScopeRegressionTest do
  use Shoestring.DataCase, async: false
  import Shoestring.Test.PlanFanoutHelpers, only: [fixture: 0, git!: 2]
  alias Shoestring.Cobbler.{PlanExecutor, PlanFanout}
  alias Shoestring.Test.PlanExecutorHelpers
  alias Shoestring.Worktrees

  # These use only APIs present at the pre-fix commit. The baseline accepts
  # the same clean commits after the real format gate passes.
  test "a passing child cannot accept a commit outside its declared files" do
    c = fixture()
    assert {:ok, result} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
    [north, _south] = result.dispatched
    {:ok, tree} = Worktrees.get(north.run_id, c.opts)
    File.write!(Path.join(tree.path, "lib/unplanned.ex"), "defmodule Unplanned do\nend\n")
    commit!(tree.path)
    complete!(c, north.run_id)

    assert {:ok, %{disposition: :scope_blocked}} =
             PlanExecutor.complete_task_run(c.goal.id, north.run_id, completion_opts(c))

    assert {:ok, %{accepted: [], needs_user?: true}} = PlanExecutor.status(c.goal.id, c.opts)
    assert File.exists?(Path.join(tree.path, "lib/unplanned.ex"))
    assert git!(c.source, ["status", "--porcelain"]) == ""
  end

  test "an unexpected overlap preserves the previously accepted sibling" do
    c = fixture()
    assert {:ok, result} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
    [north, south] = result.dispatched
    {:ok, left} = Worktrees.get(north.run_id, c.opts)

    File.write!(
      Path.join(left.path, "lib/north.ex"),
      "defmodule North do\n  def done, do: true\nend\n"
    )

    commit!(left.path)
    complete!(c, north.run_id)

    assert {:ok, %{disposition: :accepted}} =
             PlanExecutor.complete_task_run(c.goal.id, north.run_id, completion_opts(c))

    {:ok, right} = Worktrees.get(south.run_id, c.opts)

    File.write!(
      Path.join(right.path, "lib/north.ex"),
      "defmodule North do\n  def conflict, do: true\nend\n"
    )

    commit!(right.path)
    complete!(c, south.run_id)

    assert {:ok, %{disposition: :scope_blocked}} =
             PlanExecutor.complete_task_run(c.goal.id, south.run_id, completion_opts(c))

    assert {:ok, %{accepted: ["north"], needs_user?: true, total_attempts: 2}} =
             PlanExecutor.status(c.goal.id, c.opts)

    assert File.exists?(Path.join(left.path, "lib/north.ex"))
    assert File.exists?(Path.join(right.path, "lib/north.ex"))
  end

  test "a successful gate does not authorize edits to shared configuration" do
    c = fixture()
    assert {:ok, result} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
    [north, _south] = result.dispatched
    {:ok, tree} = Worktrees.get(north.run_id, c.opts)
    File.mkdir_p!(Path.join(tree.path, "config"))
    File.write!(Path.join(tree.path, "config/runtime.exs"), "import Config\n")
    commit!(tree.path)
    complete!(c, north.run_id)

    assert {:ok, %{disposition: :scope_blocked}} =
             PlanExecutor.complete_task_run(c.goal.id, north.run_id, completion_opts(c))
  end

  defp commit!(path) do
    git!(path, ["add", "."])
    git!(path, ["commit", "-m", "Retained final scope fixture"])
  end

  defp completion_opts(c),
    do: Keyword.put(c.opts, :reconciliation_opts, group_probe: fn _ -> :absent end)

  defp complete!(c, run_id) do
    assert {:ok, _} =
             Shoestring.Trajectory.append(
               c.goal.id,
               %{
                 "type" => "run.starting",
                 "schema_version" => 1,
                 "actor" => "test",
                 "occurred_at" => PlanExecutorHelpers.now(),
                 "payload" => %{"run_id" => run_id}
               },
               trusted: [run_id: run_id]
             )

    assert {:ok, _} =
             Shoestring.Trajectory.append(
               c.goal.id,
               %{
                 "type" => "run.running",
                 "schema_version" => 1,
                 "actor" => "test",
                 "occurred_at" => PlanExecutorHelpers.now(),
                 "payload" => %{"run_id" => run_id, "process_id" => "pgid:424242"}
               },
               trusted: [run_id: run_id]
             )

    PlanExecutorHelpers.complete_run!(c.goal, run_id)
  end
end
