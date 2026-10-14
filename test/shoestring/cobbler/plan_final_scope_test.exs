defmodule Shoestring.Cobbler.PlanFinalScopeTest do
  @moduledoc "New final-scope capability tests; the separate regression file verifies the old APIs."
  use Shoestring.DataCase, async: false
  import Shoestring.Test.PlanFanoutHelpers

  alias Shoestring.Cobbler.{
    PlanExecutor,
    PlanFanout,
    PlanFinalScope,
    PlanIndependence,
    Reservations
  }

  alias Shoestring.Harness.{Projector, RunRecord}
  alias Shoestring.Test.PlanExecutorHelpers
  alias Shoestring.Trajectory.{EventRegistry, TrajectoryEvent}
  alias Shoestring.Worktrees

  test "final files bind the tested commit and replay without running gates again" do
    {c, north, _south, tree} = dispatched()
    change!(tree, "lib/north.ex")
    complete_child!(c.goal, north.run_id)
    assert {:ok, %{disposition: :accepted, commit: commit}} = complete(c, north)

    event =
      Repo.get_by!(TrajectoryEvent, type: "cobbler.plan.task.accepted", run_id: north.run_id)

    assert {:ok, scope} = PlanFinalScope.decode(event.payload["scope_json"])

    assert scope == %{
             "version" => 1,
             "accepted_base" => c.base,
             "commit" => commit,
             "root_run_id" => north.run_id,
             "files" => ["lib/north.ex"]
           }

    assert {:ok, %{disposition: :replayed}} =
             PlanExecutor.complete_task_run(
               c.goal.id,
               north.run_id,
               Keyword.put(c.opts, :gate_runner_opts,
                 runner: fn _, _, _ -> flunk("gate replay") end
               )
             )

    assert {:ok, _} = Projector.rebuild(c.goal.id)

    assert {:ok, %{accepted: ["north"], scope_blockers: []}} =
             PlanExecutor.status(c.goal.id, c.opts)
  end

  test "scope conflicts preserve passed gates, count their duration once and stop all admission" do
    {c, north, _south, tree} = dispatched()
    change!(tree, "lib/unplanned.ex")
    complete_child!(c.goal, north.run_id)
    assert {:ok, %{disposition: :scope_blocked, commit: commit}} = complete(c, north)

    event =
      Repo.get_by!(TrajectoryEvent, type: "cobbler.plan.task.scope_blocked", run_id: north.run_id)

    assert [%{"exit_status" => 0, "commit" => ^commit, "duration_ms" => ms}] =
             event.payload["evidence"]["gates"]

    assert {:ok, %{"blockers" => blockers}} =
             PlanIndependence.decode_event_decision(event.payload["decision_json"])

    assert Enum.any?(blockers, &(&1["reason"] == "outside_declared_scope"))
    assert {:ok, status} = PlanExecutor.status(c.goal.id, c.opts)
    assert status.total_gate_duration_ms == ms
    assert status.needs_user? and status.accepted == [] and length(status.scope_blockers) == 1
    assert Enum.find(status.children, &(&1.run_id == north.run_id)).resolution == :scope_blocked
    assert {:ok, %{disposition: :replayed}} = complete(c, north)
    assert {:ok, _} = Projector.rebuild(c.goal.id)
    assert {:ok, rebuilt} = PlanExecutor.status(c.goal.id, c.opts)
    assert rebuilt.scope_blockers == status.scope_blockers
    assert rebuilt.total_gate_duration_ms == ms

    assert {:error, :fanout_scope_resolution_required} =
             PlanFanout.dispatch_ready(
               c.goal.id,
               Keyword.put(c.opts, :admission_fun, fn _, _, _, _ ->
                 flunk("conflict admission")
               end)
             )

    assert Repo.aggregate(RunRecord, :count) == 2
    refute Enum.any?(Reservations.outstanding(), &(&1.run_id == north.run_id))
    assert git!(tree.path, ["rev-parse", "HEAD"]) |> String.trim() == commit
  end

  test "missing process identity retains ownership and does not run acceptance gates" do
    {c, north, _south, _tree} = dispatched()
    PlanExecutorHelpers.complete_run!(c.goal, north.run_id)

    assert {:error, :fanout_child_not_quiescent} =
             PlanExecutor.complete_task_run(
               c.goal.id,
               north.run_id,
               Keyword.put(c.opts, :gate_runner_opts,
                 runner: fn _, _, _ -> flunk("uncertain process gate") end
               )
             )

    assert length(Reservations.outstanding()) == 2
    assert {:ok, %{accepted: []}} = PlanExecutor.status(c.goal.id, c.opts)
  end

  test "an unrelated sibling can retain acceptance after a conflict is recorded" do
    {c, north, south, tree} = dispatched()
    change!(tree, "lib/unplanned.ex")
    complete_child!(c.goal, north.run_id)
    assert {:ok, %{disposition: :scope_blocked}} = complete(c, north)
    complete_child!(c.goal, south.run_id)
    assert {:ok, %{disposition: :accepted}} = complete(c, south)

    assert {:ok, %{accepted: ["south"], scope_blockers: [_], needs_user?: true}} =
             PlanExecutor.status(c.goal.id, c.opts)

    assert {:error, :fanout_scope_resolution_required} =
             PlanFanout.dispatch_ready(c.goal.id, c.opts)
  end

  test "an alive owned group cannot be overridden by a successful terminal event" do
    {c, north, _south, _tree} = dispatched()
    complete_child!(c.goal, north.run_id)
    opts = Keyword.put(c.opts, :reconciliation_opts, group_probe: fn _ -> :alive end)

    assert {:error, :fanout_child_not_quiescent} =
             PlanExecutor.complete_task_run(c.goal.id, north.run_id, opts)

    assert length(Reservations.outstanding()) == 2
  end

  test "an accepted branch moved after verification cannot rewrite its scope" do
    {c, north, south, tree} = dispatched()
    complete_child!(c.goal, north.run_id)
    assert {:ok, %{disposition: :accepted}} = complete(c, north)
    change!(tree, "lib/north.ex")
    complete_child!(c.goal, south.run_id)
    assert {:ok, %{disposition: :scope_blocked}} = complete(c, south)

    event =
      Repo.get_by!(TrajectoryEvent, type: "cobbler.plan.task.scope_blocked", run_id: south.run_id)

    assert event.payload["reason"] == "fanout_child_scope_unavailable"
    refute Map.has_key?(event.payload, "scope_json")

    assert {:error, :fanout_scope_resolution_required} =
             PlanFanout.dispatch_ready(c.goal.id, c.opts)

    assert {:ok, %{accepted: ["north"]}} = PlanExecutor.status(c.goal.id, c.opts)
  end

  test "a final symlink never becomes accepted file evidence" do
    {c, north, _south, tree} = dispatched()
    assert :ok = File.ln_s("south.ex", Path.join(tree.path, "lib/link.ex"))
    commit!(tree)
    complete_child!(c.goal, north.run_id)
    assert {:ok, %{disposition: :scope_blocked}} = complete(c, north)

    event =
      Repo.get_by!(TrajectoryEvent, type: "cobbler.plan.task.scope_blocked", run_id: north.run_id)

    assert event.payload["reason"] == "changed_scope_invalid_or_oversized"
    assert [%{"exit_status" => 0}] = event.payload["evidence"]["gates"]
    refute Map.has_key?(event.payload, "scope_json")
    assert {:ok, %{accepted: []}} = PlanExecutor.status(c.goal.id, c.opts)
    assert {:ok, %{type: :symlink}} = File.lstat(Path.join(tree.path, "lib/link.ex"))
  end

  test "deletions and both rename endpoints appear in immutable final evidence" do
    {c, north, _south, tree} = dispatched()
    git!(tree.path, ["mv", "lib/north.ex", "lib/renamed.ex"])
    commit!(tree)
    complete_child!(c.goal, north.run_id)
    assert {:ok, %{disposition: :scope_blocked}} = complete(c, north)

    event =
      Repo.get_by!(TrajectoryEvent, type: "cobbler.plan.task.scope_blocked", run_id: north.run_id)

    assert {:ok, %{"files" => ["lib/north.ex", "lib/renamed.ex"]}} =
             PlanFinalScope.decode(event.payload["scope_json"])
  end

  test "final evidence rejects malformed, mismatched, secret-bearing and oversized values" do
    {c, north, _south, tree} = dispatched()
    complete_child!(c.goal, north.run_id)
    assert {:ok, %{disposition: :accepted}} = complete(c, north)

    event =
      Repo.get_by!(TrajectoryEvent, type: "cobbler.plan.task.accepted", run_id: north.run_id)

    assert :ok = PlanFinalScope.validate_payload(event.payload)
    assert {:ok, scope} = PlanFinalScope.decode(event.payload["scope_json"])
    assert scope["root_run_id"] == north.run_id and scope["accepted_base"] == c.base

    for bad <- [
          Map.put(scope, "commit", String.duplicate("f", 40)),
          Map.put(scope, "files", ["../escape"]),
          Map.put(scope, "files", ["lib/token=sk-test-value"]),
          Map.put(scope, "transcript", "private"),
          Map.put(scope, "files", List.duplicate("lib/north.ex", 1025))
        ] do
      payload = Map.put(event.payload, "scope_json", Jason.encode!(bad))

      assert {:error, _} =
               EventRegistry.validate_payload("cobbler.plan.task.accepted", 1, payload)
    end

    assert {:error, :invalid_final_scope} = PlanFinalScope.decode(String.duplicate(" ", 65_537))
    assert File.dir?(tree.path)
  end

  test "oversized combined scope evidence preserves the passed gate as explicitly unverified" do
    {c, north, _south, tree} = dispatched()

    for index <- 1..260 do
      file = "lib/#{index}_#{String.duplicate("a", 180)}.ex"
      File.write!(Path.join(tree.path, file), "defmodule Changed do\nend\n")
    end

    commit!(tree)
    complete_child!(c.goal, north.run_id)
    assert {:ok, %{disposition: :scope_blocked}} = complete(c, north)

    event =
      Repo.get_by!(TrajectoryEvent, type: "cobbler.plan.task.scope_blocked", run_id: north.run_id)

    assert event.payload["reason"] == "scope_evidence_oversized"
    refute Map.has_key?(event.payload, "scope_json")
    assert [%{"exit_status" => 0}] = event.payload["evidence"]["gates"]

    assert {:ok, %{"evidence_complete" => false}} =
             PlanIndependence.decode_event_decision(event.payload["decision_json"])
  end

  defp dispatched do
    c = fixture(reconciliation_opts: [group_probe: fn _ -> :absent end])
    assert {:ok, result} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
    [north, south] = result.dispatched
    {:ok, tree} = Worktrees.get(north.run_id, c.opts)
    {c, north, south, tree}
  end

  defp complete(c, child), do: PlanExecutor.complete_task_run(c.goal.id, child.run_id, c.opts)

  defp change!(tree, file) do
    File.write!(Path.join(tree.path, file), "defmodule Changed do\nend\n")
    commit!(tree)
  end

  defp commit!(tree) do
    git!(tree.path, ["add", "."])
    git!(tree.path, ["commit", "-m", "Retained final scope fixture"])
  end
end
