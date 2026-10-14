defmodule Shoestring.Cobbler.PlanGoalStatusRegressionTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.Cobbler
  alias Shoestring.Test.CobblerHelpers
  alias Shoestring.Trajectory.Goal
  import Shoestring.Test.PlanExecutorHelpers

  test "canonical planned-goal completion is reflected by the generic goal row" do
    goal = CobblerHelpers.create_goal!()
    plan = Map.update!(chain_plan(), "tasks", &Enum.take(&1, 1))
    revision = propose_and_approve!(goal, plan)
    admission = admit!(goal)

    assert {:ok, _} =
             Cobbler.request_plan_execution(
               goal.id,
               %{
                 revision_number: revision.revision_number,
                 digest: revision.digest,
                 admission_event_id: admission.id
               },
               exec_opts()
             )

    assert {:ok, run} =
             Cobbler.advance_plan_execution(
               goal.id,
               exec_opts(admission_event_id: admit!(goal).id)
             )

    complete_run!(goal, run.run_id)

    assert {:ok, %{disposition: :accepted}} =
             Cobbler.complete_plan_task_run(goal.id, run.run_id, exec_opts())

    assert {:ok, %{disposition: :completed}} =
             Cobbler.advance_plan_execution(goal.id, exec_opts())

    assert {:ok, %{completed?: true}} = Cobbler.plan_execution_status(goal.id)
    # The baseline leaves this row `active` after canonical completion.
    assert %Goal{status: "completed"} = Repo.get!(Goal, goal.id)
  end
end
