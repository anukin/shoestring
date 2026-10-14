defmodule Shoestring.Cobbler.PlanChildrenProjectionRegressionTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.Cobbler.{PlanBinding, PlanExecutor}
  alias Shoestring.Harness.{Fake, Runs}
  alias Shoestring.Test.{PlanExecutorHelpers, PlanFanoutHelpers, PlanHandoffClock}
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.Task

  defp children(c) do
    for name <- ~w(north south) do
      task = %Task{goal_id: c.goal.id} |> Task.changeset(%{title: name}) |> Repo.insert!()
      request = Shoestring.Test.ElvesHelpers.run_request(c.goal, task)

      request = %{
        request
        | extensions: %{
            PlanBinding.key() => %{
              "execution_id" => c.execution.execution_id,
              "revision_number" => c.execution.revision_number,
              "plan_digest" => c.execution.plan_digest,
              "plan_task_id" => name,
              "attempt" => 1
            }
          }
      }

      assert {:ok, run} = Runs.request(request, Fake.identity(), clock: PlanHandoffClock)

      assert {:ok, _} =
               Trajectory.append(c.goal.id, %{
                 "type" => "cobbler.plan.task.dispatched",
                 "schema_version" => 1,
                 "actor" => "test",
                 "occurred_at" => PlanExecutorHelpers.now(),
                 "payload" => %{
                   "execution_id" => c.execution.execution_id,
                   "revision_number" => c.execution.revision_number,
                   "plan_digest" => c.execution.plan_digest,
                   "plan_task_id" => name,
                   "attempt" => 1,
                   "trajectory_task_id" => task.id,
                   "run_id" => run.id,
                   "command_id" => "fixture-#{name}"
                 }
               })

      run
    end
  end

  test "status retains every unresolved child rather than just the first run" do
    c = PlanFanoutHelpers.fixture()
    runs = children(c)
    assert {:ok, status} = PlanExecutor.status(c.goal.id)
    assert Enum.sort(status.active_run_ids) == Enum.sort(Enum.map(runs, & &1.id))
  end

  test "restart continuation records a later terminal while the first child stays unresolved" do
    c = PlanFanoutHelpers.fixture()
    [north, south] = children(c)
    PlanExecutorHelpers.complete_run!(c.goal, south.id)
    opts = PlanExecutorHelpers.exec_opts(clock: PlanHandoffClock)
    assert {:ok, _} = PlanExecutor.resume(c.goal.id, opts)
    assert {:ok, status} = PlanExecutor.status(c.goal.id)
    assert status.accepted == ["south"]
    assert status.active_run_ids == [north.id]
  end
end
