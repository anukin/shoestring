defmodule Shoestring.Cobbler.PlanScopeCheckTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.Cobbler.{PlanExecutor, PlanScopeCheck, ScopeEvidence}
  alias Shoestring.Test.{CobblerHelpers, PlanExecutorHelpers, PlanFixtures}
  alias Shoestring.Trajectory.TrajectoryEvent

  setup do
    path = Path.join(System.tmp_dir!(), "shoestring-scope-#{Ecto.UUID.generate()}")
    File.mkdir_p!(Path.join(path, "lib"))
    File.write!(Path.join(path, "lib/a.ex"), "first\n")
    File.write!(Path.join(path, "lib/b.ex"), "second\n")
    git!(path, ["init"])
    git!(path, ["config", "user.name", "Fixture"])
    git!(path, ["config", "user.email", "fixture@example.invalid"])
    git!(path, ["add", "."])
    git!(path, ["commit", "-m", "Scope fixture base"])
    base = git!(path, ["rev-parse", "HEAD"]) |> String.trim()
    goal = CobblerHelpers.create_goal!()

    plan =
      PlanExecutorHelpers.independent_plan()
      |> Map.put("goal", PlanFixtures.goal(%{"repository" => %{"base_revision" => base}}))

    plan =
      Map.update!(plan, "tasks", fn [first, second] ->
        [
          Map.put(first, "hints", %{"files" => ["lib/a.ex"], "symbols" => []}),
          Map.put(second, "hints", %{"files" => ["lib/b.ex"], "symbols" => []})
        ]
      end)

    revision = PlanExecutorHelpers.propose_and_approve!(goal, plan)
    admission = PlanExecutorHelpers.admit!(goal)

    assert {:ok, _} =
             PlanExecutor.request_execution(
               goal.id,
               Map.merge(revision, %{admission_event_id: admission.id, repository_path: path}),
               PlanExecutorHelpers.exec_opts()
             )

    %{path: path, base: base, goal: goal}
  end

  defp git!(path, args) do
    {output, status} = System.cmd("git", args, cd: path, stderr_to_stdout: true)
    assert status == 0, output
    output
  end

  test "records replayable exact-base scope evidence without allocating work", c do
    assert {:ok, result} = PlanScopeCheck.record(c.goal.id)
    assert result.evidence["decision"]["disposition"] == "eligible"
    assert result.evidence["decision"]["task_ids"] == ["north", "south"]
    refute result.parallel_dispatch_enabled
    assert {:ok, repeated} = PlanScopeCheck.record(c.goal.id)
    assert result.event_id == repeated.event_id
    assert PlanExecutorHelpers.run_count(c.goal.id) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0

    assert Repo.aggregate(
             from(e in TrajectoryEvent, where: e.type == "cobbler.plan.independence.evaluated"),
             :count
           ) == 1
  end

  test "moved HEAD and dirty source produce sequential decisions rather than assumed compatibility",
       c do
    File.write!(Path.join(c.path, "lib/a.ex"), "changed\n")
    assert {:ok, dirty} = PlanScopeCheck.record(c.goal.id)
    assert dirty.evidence["decision"]["disposition"] == "sequential"
    git!(c.path, ["add", "."])
    git!(c.path, ["commit", "-m", "Moved source base"])
    assert {:ok, moved} = PlanScopeCheck.record(c.goal.id)
    assert moved.evidence["decision"]["disposition"] == "sequential"
    assert {:error, :repository_base_or_state_changed} = ScopeEvidence.repository(c.path, c.base)
    assert PlanExecutorHelpers.run_count(c.goal.id) == 0
  end

  test "Git captures tracked deletions, renames and untracked paths with NUL framing", c do
    File.rename!(Path.join(c.path, "lib/a.ex"), Path.join(c.path, "renamed file.ex"))
    File.write!(Path.join(c.path, "untracked.ex"), "new\n")
    assert {:ok, changes} = ScopeEvidence.changes(c.path, c.base)
    assert changes == ["lib/a.ex", "renamed file.ex", "untracked.ex"]

    assert {:error, :repository_base_or_state_changed} = ScopeEvidence.repository(c.path, c.base)
  end

  test "new symlinks and invalid bases fail closed", c do
    File.ln_s!("lib/a.ex", Path.join(c.path, "link"))
    assert {:error, :changed_scope_invalid_or_oversized} = ScopeEvidence.changes(c.path, c.base)
    assert {:error, :repository_base_or_state_changed} = ScopeEvidence.repository(c.path, "HEAD")
  end

  test "tracked symlink metadata is explicit and blocks descendants", c do
    File.ln_s!("a.ex", Path.join(c.path, "lib/link"))
    git!(c.path, ["add", "."])
    git!(c.path, ["commit", "-m", "Symlink fixture"])
    base = git!(c.path, ["rev-parse", "HEAD"]) |> String.trim()
    assert {:ok, metadata} = ScopeEvidence.repository(c.path, base)
    assert metadata.symlinks == ["lib/link"]

    result =
      Shoestring.Cobbler.PlanIndependence.declared(
        [%{"id" => "a", "hints" => %{"files" => ["lib/link/child.ex"]}}],
        metadata
      )

    assert result["disposition"] == "sequential"
  end

  test "active execution keeps preflight sequential and the CLI starts no new work", c do
    admission = PlanExecutorHelpers.admit!(c.goal)

    assert {:ok, _} =
             PlanExecutor.advance(
               c.goal.id,
               PlanExecutorHelpers.exec_opts(admission_event_id: admission.id)
             )

    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
    Mix.Tasks.Shoestring.Execution.run(["check-scopes", c.goal.id])
    assert_receive {:mix_shell, :info, [json]}
    result = Jason.decode!(json)
    assert result["evidence"]["decision"]["disposition"] == "sequential"
    assert result["evidence"]["decision"]["execution_blocked"]
    refute result["parallel_dispatch_enabled"]
    assert PlanExecutorHelpers.run_count(c.goal.id) == 1
    assert Repo.aggregate(Oban.Job, :count) == 1

    assert_raise Mix.Error, fn ->
      Mix.Tasks.Shoestring.Execution.run(["check-scopes", c.goal.id, "--force"])
    end
  end

  test "a changed approval cannot record old execution authority", c do
    assert {:ok, %{revision: revision}} =
             Shoestring.Cobbler.Plans.propose(
               c.goal.id,
               PlanFixtures.propose_attrs(
                 plan: PlanExecutorHelpers.independent_plan(),
                 proposal_id: "new-authority",
                 parent_revision_number: 1
               ),
               PlanExecutorHelpers.exec_opts()
             )

    assert {:ok, _} =
             Shoestring.Cobbler.Plans.approve(
               c.goal.id,
               PlanFixtures.approve_attrs(2, revision.digest, decision_id: "new-authority"),
               PlanExecutorHelpers.exec_opts()
             )

    assert {:error, :scope_execution_authority_required} = PlanScopeCheck.record(c.goal.id)

    assert Repo.aggregate(
             from(e in TrajectoryEvent, where: e.type == "cobbler.plan.independence.evaluated"),
             :count
           ) == 0
  end
end
