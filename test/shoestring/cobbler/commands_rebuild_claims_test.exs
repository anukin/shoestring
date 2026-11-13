defmodule Shoestring.Cobbler.CommandsRebuildClaimsTest do
  @moduledoc """
  A goal whose plan runs tasks one after another takes one task claim per
  task, releasing each before the next. Rebuilding its commands from the
  trajectory must accept a claim acquired after the previous one was
  released (found on the goal page after the iteration 19 live run, whose
  second task's claim made the rebuild refuse with a claim conflict).
  Hermetic: Fake-grade admission and an injected gate runner.
  """
  use Shoestring.DataCase, async: false

  import Ecto.Query
  import Shoestring.Test.PlanExecutorHelpers

  alias Shoestring.Cobbler
  alias Shoestring.Test.CobblerHelpers

  test "a two-task chain rebuilds consistently after both tasks claimed in turn" do
    goal = CobblerHelpers.create_goal!()
    rev = propose_and_approve!(goal)
    admission = admit!(goal)

    assert {:ok, _} =
             Cobbler.request_plan_execution(
               goal.id,
               %{
                 revision_number: rev.revision_number,
                 digest: rev.digest,
                 admission_event_id: admission.id
               },
               exec_opts()
             )

    for task <- ["alpha", "beta"] do
      assert {:ok, %{disposition: :dispatched, plan_task_id: ^task} = dispatched} =
               Cobbler.advance_plan_execution(
                 goal.id,
                 exec_opts(admission_event_id: admit!(goal).id)
               )

      complete_run!(goal, dispatched.run_id)

      assert {:ok, %{disposition: :accepted}} =
               Cobbler.complete_plan_task_run(goal.id, dispatched.run_id, exec_opts())
    end

    # Two claims were taken, one after the other.
    acquired =
      Repo.aggregate(
        from(e in Shoestring.Trajectory.TrajectoryEvent,
          where: e.goal_id == ^goal.id and e.type == "cobbler.claim.acquired"
        ),
        :count
      )

    assert acquired == 2

    assert {:ok, %{consistent?: true, divergences: []}} = Cobbler.rebuild_commands(goal.id)
  end

  test "a claim acquired while another is still active is still a conflict" do
    goal = CobblerHelpers.create_goal!()
    rev = propose_and_approve!(goal)
    admission = admit!(goal)

    assert {:ok, _} =
             Cobbler.request_plan_execution(
               goal.id,
               %{
                 revision_number: rev.revision_number,
                 digest: rev.digest,
                 admission_event_id: admission.id
               },
               exec_opts()
             )

    assert {:ok, %{disposition: :dispatched}} =
             Cobbler.advance_plan_execution(goal.id, exec_opts(admission_event_id: admission.id))

    [acquired] =
      Repo.all(
        from(e in Shoestring.Trajectory.TrajectoryEvent,
          where: e.goal_id == ^goal.id and e.type == "cobbler.claim.acquired"
        )
      )

    claim_id = Ecto.UUID.generate()

    {:ok, _} =
      Shoestring.Trajectory.append(goal.id, %{
        "type" => "cobbler.claim.acquired",
        "schema_version" => acquired.schema_version,
        "actor" => acquired.actor,
        "occurred_at" => now(),
        "idempotency_key" => "forged-second-claim",
        "payload" => %{acquired.payload | "claim_id" => claim_id}
      })

    assert {:error, {:rebuild_claim_conflict, _sequence, ^claim_id}} =
             Cobbler.rebuild_commands(goal.id)
  end
end
