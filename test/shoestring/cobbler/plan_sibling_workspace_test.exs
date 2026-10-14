defmodule Shoestring.Cobbler.PlanSiblingWorkspaceTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.Cobbler.{PlanExecutor, PlanSiblingWorkspace}
  alias Shoestring.Test.{CobblerHelpers, PlanExecutorHelpers, PlanFixtures}
  alias Shoestring.{Repo, Worktrees}
  alias Shoestring.Trajectory.TrajectoryEvent

  setup do
    root = Path.join(System.tmp_dir!(), "shoestring-siblings-#{Ecto.UUID.generate()}")
    source = Path.join(root, "source")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "first.txt"), "initial\n")
    git!(source, ["init"])
    git!(source, ["config", "user.name", "Fixture"])
    git!(source, ["config", "user.email", "fixture@example.invalid"])
    git!(source, ["add", "."])
    git!(source, ["commit", "-m", "Sibling fixture base"])
    base = git!(source, ["rev-parse", "HEAD"]) |> String.trim()
    goal = CobblerHelpers.create_goal!()

    plan =
      PlanExecutorHelpers.independent_plan()
      |> Map.put("goal", PlanFixtures.goal(%{"repository" => %{"base_revision" => base}}))

    revision = PlanExecutorHelpers.propose_and_approve!(goal, plan)
    admission = PlanExecutorHelpers.admit!(goal)

    assert {:ok, %{execution: execution}} =
             PlanExecutor.request_execution(
               goal.id,
               Map.put(revision, :admission_event_id, admission.id),
               PlanExecutorHelpers.exec_opts()
             )

    %{
      goal: goal,
      source: source,
      base: base,
      execution: execution,
      opts: [repository_path: source, worktrees_dir: Path.join(root, "worktrees")]
    }
  end

  defp git!(path, args) do
    {output, status} = System.cmd("git", args, cd: path, stderr_to_stdout: true)
    assert status == 0, output
    output
  end

  test "siblings use the accepted base and separate private Git storage without modifying source",
       c do
    assert {:ok, left} = PlanSiblingWorkspace.prepare(c.goal.id, c.execution, "north", 1, c.opts)
    File.write!(Path.join(left.worktree.path, "north.txt"), "north only\n")
    git!(left.worktree.path, ["add", "."])
    git!(left.worktree.path, ["commit", "-m", "North output"])
    assert {:ok, right} = PlanSiblingWorkspace.prepare(c.goal.id, c.execution, "south", 1, c.opts)
    assert left.worktree.base_commit == c.base
    assert right.worktree.base_commit == c.base
    assert left.worktree.repo_path != right.worktree.repo_path
    assert left.worktree.path != right.worktree.path
    refute File.exists?(Path.join(right.worktree.path, "north.txt"))
    assert git!(right.worktree.path, ["rev-parse", "HEAD"]) |> String.trim() == c.base
    assert git!(c.source, ["rev-parse", "HEAD"]) |> String.trim() == c.base
    assert git!(c.source, ["status", "--porcelain"]) == ""
    assert git!(c.source, ["branch", "--list", "shoestring/*"]) == ""
    refute File.exists?(Path.join(c.source, ".git/worktrees"))
    assert git!(left.worktree.path, ["remote"]) == ""
    assert git!(right.worktree.path, ["remote"]) == ""
    assert PlanExecutorHelpers.run_count(c.goal.id) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "clean inert allocation replays the same manifest and canonical event", c do
    assert {:ok, first} = PlanSiblingWorkspace.prepare(c.goal.id, c.execution, "north", 1, c.opts)

    assert {:ok, repeated} =
             PlanSiblingWorkspace.prepare(c.goal.id, c.execution, "north", 1, c.opts)

    assert repeated.worktree == first.worktree
    assert repeated.event_id == first.event_id
    assert first.run_id == PlanExecutor.task_run_id(c.goal.id, "north", 1)

    assert Repo.aggregate(
             from(e in TrajectoryEvent, where: e.type == "cobbler.plan.workspace.prepared"),
             :count
           ) == 1
  end

  test "dirty or committed unowned allocation is refused and all evidence is preserved", c do
    assert {:ok, first} = PlanSiblingWorkspace.prepare(c.goal.id, c.execution, "north", 1, c.opts)
    file = Path.join(first.worktree.path, "retained.txt")
    File.write!(file, "preserve this work\n")

    assert {:error, :repository_base_or_state_changed} =
             PlanSiblingWorkspace.prepare(c.goal.id, c.execution, "north", 1, c.opts)

    git!(first.worktree.path, ["add", "."])
    git!(first.worktree.path, ["commit", "-m", "Preserved unowned output"])
    commit = git!(first.worktree.path, ["rev-parse", "HEAD"])

    assert {:error, :repository_base_or_state_changed} =
             PlanSiblingWorkspace.prepare(c.goal.id, c.execution, "north", 1, c.opts)

    assert File.read!(file) == "preserve this work\n"
    assert git!(first.worktree.path, ["rev-parse", "HEAD"]) == commit
    assert {:ok, stored} = Worktrees.get(first.run_id, c.opts)
    assert stored == first.worktree
  end

  test "changed source and stale plan bindings allocate nothing", c do
    File.write!(Path.join(c.source, "first.txt"), "source changed\n")

    assert {:error, :repository_base_or_state_changed} =
             PlanSiblingWorkspace.prepare(c.goal.id, c.execution, "north", 1, c.opts)

    stale = %{c.execution | plan_digest: String.duplicate("0", 64)}

    assert {:error, :sibling_workspace_authority_mismatch} =
             PlanSiblingWorkspace.prepare(c.goal.id, stale, "north", 1, c.opts)

    assert Worktrees.list(c.opts) == []
    assert PlanExecutorHelpers.run_count(c.goal.id) == 0
  end

  test "a foreign existing manifest cannot be silently adopted", c do
    id = PlanExecutor.task_run_id(c.goal.id, "north", 1)

    assert {:ok, foreign} =
             Worktrees.create(
               c.source,
               id,
               c.base,
               Keyword.merge(c.opts, private_git: true, metadata: %{"foreign" => true})
             )

    assert {:error, :sibling_workspace_binding_mismatch} =
             PlanSiblingWorkspace.prepare(c.goal.id, c.execution, "north", 1, c.opts)

    assert {:ok, ^foreign} = Worktrees.get(id, c.opts)

    assert Repo.aggregate(
             from(e in TrajectoryEvent, where: e.type == "cobbler.plan.workspace.prepared"),
             :count
           ) == 0
  end

  test "foreign execution IDs and skipped attempts cannot allocate", c do
    foreign = %{c.execution | execution_id: Ecto.UUID.generate()}

    assert {:error, :sibling_workspace_authority_mismatch} =
             PlanSiblingWorkspace.prepare(c.goal.id, foreign, "north", 1, c.opts)

    assert {:error, :sibling_workspace_authority_mismatch} =
             PlanSiblingWorkspace.prepare(c.goal.id, c.execution, "north", 2, c.opts)

    assert Worktrees.list(c.opts) == []
  end

  test "dirty work owned by the same persisted run is replayed without resetting it", c do
    assert {:ok, prepared} =
             PlanSiblingWorkspace.prepare(c.goal.id, c.execution, "north", 1, c.opts)

    task =
      %Shoestring.Trajectory.Task{}
      |> Shoestring.Trajectory.Task.changeset(%{"title" => "North"})
      |> Ecto.Changeset.put_change(:goal_id, c.goal.id)
      |> Repo.insert!()

    request = Shoestring.Test.ElvesHelpers.run_request(c.goal, task)

    request = %{
      request
      | workspace_ref: prepared.worktree.workspace_ref,
        extensions: %{
          "shoestring.plan:binding" => prepared.worktree.metadata["shoestring.plan:binding"]
        }
    }

    assert {:ok, _} =
             Shoestring.Harness.Runs.request(request, Shoestring.Harness.Fake.identity(),
               run_id: prepared.run_id
             )

    file = Path.join(prepared.worktree.path, "owned-work.txt")
    File.write!(file, "still useful\n")

    assert {:ok, replayed} =
             PlanSiblingWorkspace.prepare(c.goal.id, c.execution, "north", 1, c.opts)

    assert replayed.worktree == prepared.worktree
    assert File.read!(file) == "still useful\n"
  end
end
