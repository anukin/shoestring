defmodule Shoestring.Cobbler.PlanVerificationBudgetTest do
  use Shoestring.DataCase, async: false
  import Shoestring.Test.PlanFanoutHelpers

  alias Shoestring.Cobbler.{PlanExecutor, PlanFanout, ScopeEvidence}
  alias Shoestring.Harness.Projector
  alias Shoestring.Trajectory.{EventRegistry, TrajectoryEvent}
  alias Shoestring.Worktrees

  defp fixture!(overrides \\ []) do
    fixture(Keyword.put(overrides, :reconciliation_opts, group_probe: fn _ -> :absent end))
  end

  defp stepping_clock(values) do
    {:ok, agent} = Agent.start_link(fn -> values end)
    fn -> Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end) end
  end

  test "the worst-case bound counts every bounded Git observation" do
    assert ScopeEvidence.final_scope_bound_ms(0) == 17 * 5_000
    assert ScopeEvidence.final_scope_bound_ms(6) == 59 * 5_000
  end

  test "admission succeeds exactly when the worst-case verification allowance fits" do
    # One held owner: 300s task + 120s global gate + 295s final scope = 715s.
    c = fixture!(independent_only: true, task_seconds: 300, goal_seconds: 715)
    assert {:ok, result} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
    assert [%{plan_task_id: "north"}] = result.dispatched

    assert [%{plan_task_id: "south", reason: :fanout_duration_allowance_exhausted}] =
             result.blocked
  end

  test "measured final-scope time is charged once to the goal, never to the task" do
    c = fixture!()
    assert {:ok, %{dispatched: [north, _south]}} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
    {:ok, tree} = Worktrees.get(north.run_id, c.opts)

    File.write!(
      Path.join(tree.path, "lib/north.ex"),
      "defmodule North do\n  def verified, do: true\nend\n"
    )

    git!(tree.path, ["add", "."])
    git!(tree.path, ["commit", "-m", "North change"])
    complete_child!(c.goal, north.run_id)

    opts = Keyword.put(c.opts, :monotonic_ms_fun, stepping_clock([1_000, 1_750]))

    assert {:ok, %{disposition: :accepted}} =
             PlanExecutor.complete_task_run(c.goal.id, north.run_id, opts)

    event =
      Repo.get_by!(TrajectoryEvent, type: "cobbler.plan.task.accepted", run_id: north.run_id)

    assert event.payload["verification_overhead_ms"] == 750
    gate_ms = hd(event.payload["evidence"]["gates"])["duration_ms"]

    assert {:ok, status} = PlanExecutor.status(c.goal.id, c.opts)
    assert status.total_verification_overhead_ms == 750
    assert status.total_gate_duration_ms == gate_ms
    assert status.total_duration_ms == status.total_run_duration_ms + gate_ms + 750
    assert status.task_duration_ms["north"] == gate_ms

    # Replay neither re-measures nor charges the overhead again.
    assert {:ok, %{disposition: :replayed}} =
             PlanExecutor.complete_task_run(c.goal.id, north.run_id, c.opts)

    assert {:ok, _} = Projector.rebuild(c.goal.id)
    assert {:ok, %{total_verification_overhead_ms: 750}} = PlanExecutor.status(c.goal.id, c.opts)
  end

  test "the canonical field must be a bounded non-negative integer" do
    base = %{
      "execution_id" => Ecto.UUID.generate(),
      "plan_task_id" => "north",
      "revision_number" => 1,
      "plan_digest" => String.duplicate("a", 64),
      "run_id" => Ecto.UUID.generate(),
      "attempt" => 1,
      "gate" => "mix_format_check",
      "gate_argv" => ["mix", "format", "--check-formatted"],
      "commit" => String.duplicate("b", 40),
      "evidence" => %{"gates" => []}
    }

    for value <- [-1, 86_400_001] do
      assert {:error, _} =
               EventRegistry.validate_payload(
                 "cobbler.plan.task.accepted",
                 1,
                 Map.put(base, "verification_overhead_ms", value)
               )
    end

    assert {:ok, _} =
             EventRegistry.validate_payload(
               "cobbler.plan.task.accepted",
               1,
               Map.put(base, "verification_overhead_ms", 0)
             )
  end
end
