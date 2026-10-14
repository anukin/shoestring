defmodule Shoestring.Cobbler.PlanScopeResolutionTest do
  use Shoestring.DataCase, async: false
  import Shoestring.Test.PlanFanoutHelpers

  alias Shoestring.Cobbler.{ExecutionControl, PlanExecutor, PlanFanout}
  alias Shoestring.Harness.Projector
  alias Shoestring.Trajectory.{EventRegistry, TrajectoryEvent}
  alias Shoestring.Worktrees

  defp blocked do
    c = fixture(reconciliation_opts: [group_probe: fn _ -> :absent end])
    assert {:ok, %{dispatched: [north, south]}} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
    {:ok, tree} = Worktrees.get(north.run_id, c.opts)
    File.write!(Path.join(tree.path, "lib/unplanned.ex"), "defmodule Unplanned do\nend\n")
    git!(tree.path, ["add", "."])
    git!(tree.path, ["commit", "-m", "Out-of-scope change"])
    complete_child!(c.goal, north.run_id)
    assert {:ok, %{disposition: :scope_blocked}} = complete(c, north)
    {c, north, south}
  end

  defp complete(c, child), do: PlanExecutor.complete_task_run(c.goal.id, child.run_id, c.opts)

  defp resolve(c, decision, overrides \\ %{}) do
    ExecutionControl.resolve_scope(
      c.goal.id,
      Map.merge(
        %{
          execution_id: c.execution.execution_id,
          task_id: "north",
          attempt: 1,
          decision: decision,
          reason: "Reviewed the out-of-scope file; it is intended.",
          command_id: "01950000-0000-7000-8000-0000000000a1",
          requested_by: "human:operator"
        },
        overrides
      )
    )
  end

  test "accepting keeps the tested commit, clears only that blocker and counts gate time once" do
    {c, north, south} = blocked()
    assert {:ok, before} = PlanExecutor.status(c.goal.id, c.opts)
    [blocker] = before.scope_blockers

    assert {:ok, event} = resolve(c, "accept")
    assert event.payload["blocked_event_id"] == blocker.event_id
    refute Map.has_key?(event.payload, "retry_state")

    assert {:ok, status} = PlanExecutor.status(c.goal.id, c.opts)
    assert status.accepted == ["north"]
    assert status.scope_blockers == []

    assert Enum.any?(
             status.acknowledged_scope_blockers,
             &(&1["reason"] == "outside_declared_scope")
           )

    assert status.total_gate_duration_ms == before.total_gate_duration_ms
    assert Enum.find(status.children, &(&1.run_id == north.run_id)).resolution == :accepted
    assert hd(status.accepted_evidence).commit == blocker.commit

    # The acknowledged blocker no longer stops later assessment of the sibling.
    complete_child!(c.goal, south.run_id)
    assert {:ok, %{disposition: :accepted}} = complete(c, south)

    assert {:ok, %{accepted: ["north", "south"], scope_blockers: []}} =
             PlanExecutor.status(c.goal.id, c.opts)

    # Dependents still need human integration at the approved base; nothing merges.
    assert {:ok, %{dispatched: [], blocked: [%{plan_task_id: "join", reason: reason}]}} =
             PlanFanout.dispatch_ready(c.goal.id, c.opts)

    assert reason == :fanout_inputs_require_integration
    assert {:ok, _} = Projector.rebuild(c.goal.id)
    assert {:ok, %{accepted: ["north", "south"]}} = PlanExecutor.status(c.goal.id, c.opts)
  end

  test "rejecting resolves the attempt with a bounded retry state and no admission" do
    {c, north, _south} = blocked()
    assert {:ok, event} = resolve(c, "reject")
    assert event.payload["retry_state"] == "retry"

    assert {:ok, status} = PlanExecutor.status(c.goal.id, c.opts)
    assert status.accepted == []
    assert status.scope_blockers == []
    assert status.acknowledged_scope_blockers == []
    child = Enum.find(status.children, &(&1.run_id == north.run_id))
    assert {child.resolution, child.retry_state} == {:scope_rejected, "retry"}
    refute status.needs_user?
  end

  test "identical replay converges; a different decision or stale identity is refused" do
    {c, _north, _south} = blocked()
    assert {:ok, event} = resolve(c, "accept")
    assert {:ok, ^event} = resolve(c, "accept")
    assert {:error, :scope_resolution_conflict} = resolve(c, "reject")

    assert {:error, :scope_resolution_conflict} =
             resolve(c, "accept", %{command_id: "01950000-0000-7000-8000-0000000000a2"})

    assert {:error, :scope_resolution_mismatch} =
             resolve(c, "accept", %{
               task_id: "south",
               command_id: "01950000-0000-7000-8000-0000000000a3"
             })

    assert {:error, :scope_resolution_mismatch} =
             resolve(c, "reject", %{
               attempt: 2,
               command_id: "01950000-0000-7000-8000-0000000000a4"
             })

    assert 1 ==
             Repo.aggregate(
               from(e in TrajectoryEvent, where: e.type == "cobbler.plan.task.scope_resolved"),
               :count
             )
  end

  test "commands require a human identity, a known decision and a bounded reason" do
    {c, _north, _south} = blocked()

    for overrides <- [
          %{requested_by: "cobbler"},
          %{decision: "merge"},
          %{reason: "  "},
          %{reason: String.duplicate("r", 2001)},
          %{command_id: "not-a-uuid"},
          %{attempt: 0}
        ] do
      assert {:error, :invalid_scope_resolution} = resolve(c, "accept", overrides)
    end

    assert {:ok, %{scope_blockers: [_]}} = PlanExecutor.status(c.goal.id, c.opts)
  end

  test "the registry refuses a resolution that is not a well-formed human decision" do
    base = %{
      "resolution_id" => Ecto.UUID.generate(),
      "execution_id" => Ecto.UUID.generate(),
      "revision_number" => 1,
      "plan_digest" => String.duplicate("a", 64),
      "plan_task_id" => "north",
      "attempt" => 1,
      "run_id" => Ecto.UUID.generate(),
      "blocked_event_id" => Ecto.UUID.generate(),
      "decision" => "accept",
      "resolved_by" => "human:operator",
      "reason" => "Reviewed."
    }

    validate = &EventRegistry.validate_payload("cobbler.plan.task.scope_resolved", 1, &1)
    assert {:ok, _} = validate.(base)

    assert {:ok, _} =
             validate.(%{base | "decision" => "reject"} |> Map.put("retry_state", "retry"))

    assert {:error, _} = validate.(%{base | "decision" => "reject"})
    assert {:error, _} = validate.(Map.put(base, "retry_state", "retry"))
    assert {:error, _} = validate.(%{base | "resolved_by" => "cobbler"})
    assert {:error, _} = validate.(%{base | "decision" => "merge"})
  end
end
