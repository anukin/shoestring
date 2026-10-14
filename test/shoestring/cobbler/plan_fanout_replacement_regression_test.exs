defmodule Shoestring.Cobbler.PlanFanoutReplacementRegressionTest do
  use Shoestring.DataCase, async: false
  import Shoestring.Test.PlanFanoutHelpers
  alias Shoestring.Cobbler.{PlanExecutor, PlanFanout}
  alias Shoestring.Test.PlanExecutorHelpers
  alias Shoestring.Trajectory

  test "a failed fan-out child with attempts remaining is replaced through admission" do
    c =
      fixture(independent_only: true, reconciliation_opts: [group_probe: fn _ -> :absent end])

    assert {:ok, %{dispatched: [north, _south]}} = PlanFanout.dispatch_ready(c.goal.id, c.opts)

    for {type, payload} <- [
          {"run.starting", %{}},
          {"run.running", %{"process_id" => "pgid:424242"}},
          {"run.failed", %{"error_category" => "task_failed", "error_code" => "tests_failed"}}
        ] do
      assert {:ok, _} =
               Trajectory.append(
                 c.goal.id,
                 %{
                   "type" => type,
                   "schema_version" => 1,
                   "actor" => "test",
                   "occurred_at" => PlanExecutorHelpers.now(),
                   "payload" => Map.put(payload, "run_id", north.run_id)
                 },
                 trusted: [run_id: north.run_id]
               )
    end

    assert {:ok, %{retry_state: "retry"}} =
             PlanExecutor.complete_task_run(c.goal.id, north.run_id, c.opts)

    # The baseline coordinator only admits first attempts, so it returns [].
    assert {:ok, %{dispatched: [%{plan_task_id: "north", attempt: 2}]}} =
             PlanFanout.dispatch_ready(c.goal.id, c.opts)
  end
end
