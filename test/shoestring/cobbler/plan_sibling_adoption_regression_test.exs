defmodule Shoestring.Cobbler.PlanSiblingAdoptionRegressionTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.Cobbler.{PlanExecutor, PlanSiblingWorkspace}
  alias Shoestring.Test.PlanFanoutHelpers

  test "ordinary execution cannot adopt dirty unowned sibling storage" do
    c = PlanFanoutHelpers.fixture(worktrees_dir: Shoestring.State.path(:worktrees))

    assert {:ok, prepared} =
             PlanSiblingWorkspace.prepare(c.goal.id, c.execution, "north", 1, c.opts)

    file = Path.join(prepared.worktree.path, "retained.txt")
    File.write!(file, "retain unowned work\n")

    assert {:error, :fanout_workspace_requires_coordinator} =
             PlanExecutor.advance(c.goal.id, c.opts)

    assert File.read!(file) == "retain unowned work\n"

    assert PlanFanoutHelpers.git!(prepared.worktree.path, ["rev-parse", "HEAD"]) |> String.trim() ==
             c.base

    assert Repo.aggregate(Shoestring.Harness.RunRecord, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
  end
end
