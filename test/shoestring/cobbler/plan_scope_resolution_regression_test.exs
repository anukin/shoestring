defmodule Shoestring.Cobbler.PlanScopeResolutionRegressionTest do
  use Shoestring.DataCase, async: false
  import Shoestring.Test.PlanFanoutHelpers
  alias Shoestring.Cobbler.{PlanExecutor, PlanFanout}
  alias Shoestring.Worktrees

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
  end

  test "an operator can clear a recorded scope blocker through the execution CLI" do
    c = fixture(reconciliation_opts: [group_probe: fn _ -> :absent end])
    assert {:ok, %{dispatched: [north, _south]}} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
    {:ok, tree} = Worktrees.get(north.run_id, c.opts)
    File.write!(Path.join(tree.path, "lib/unplanned.ex"), "defmodule Unplanned do\nend\n")
    git!(tree.path, ["add", "."])
    git!(tree.path, ["commit", "-m", "Out-of-scope change"])
    complete_child!(c.goal, north.run_id)

    assert {:ok, %{disposition: :scope_blocked}} =
             PlanExecutor.complete_task_run(c.goal.id, north.run_id, c.opts)

    # The baseline CLI refuses this request, leaving the blocker permanent.
    Mix.Tasks.Shoestring.Execution.run([
      "resolve-scope",
      c.goal.id,
      "--execution-id",
      c.execution.execution_id,
      "--task-id",
      "north",
      "--attempt",
      "1",
      "--decision",
      "accept",
      "--reason",
      "Reviewed the out-of-scope file.",
      "--command-id",
      "01950000-0000-7000-8000-0000000000b1",
      "--by",
      "human:operator"
    ])

    assert_receive {:mix_shell, :info, [_json]}

    assert {:ok, %{accepted: ["north"], scope_blockers: []}} =
             PlanExecutor.status(c.goal.id, c.opts)
  end
end
