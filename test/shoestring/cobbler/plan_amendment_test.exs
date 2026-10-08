defmodule Shoestring.Cobbler.PlanAmendmentTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.Cobbler
  alias Shoestring.Cobbler.Plans
  alias Shoestring.Test.{CobblerHelpers, PlanFixtures}
  import Shoestring.Test.PlanExecutorHelpers

  defp request(goal, revision) do
    admission = admit!(goal)

    Cobbler.request_plan_execution(
      goal.id,
      %{
        revision_number: revision.revision_number,
        digest: revision.digest,
        admission_event_id: admission.id
      },
      exec_opts()
    )
  end

  defp dispatch!(goal) do
    admission = admit!(goal)

    assert {:ok, result} =
             Cobbler.advance_plan_execution(goal.id, exec_opts(admission_event_id: admission.id))

    result
  end

  defp approve!(goal, revision) do
    attrs =
      PlanFixtures.approve_attrs(revision.revision_number, revision.digest,
        decision_id: "approve-#{revision.revision_number}"
      )

    result = Plans.approve(goal.id, attrs, now: now(), publish_fun: fn _ -> :ok end)
    assert {:ok, _} = result
  end

  defp proposal(goal, plan, parent, key) do
    Plans.propose(
      goal.id,
      PlanFixtures.propose_attrs(plan: plan, parent_revision_number: parent, proposal_id: key),
      now: now(),
      publish_fun: fn _ -> :ok end
    )
  end

  defp changed(plan, id) do
    Map.update!(plan, "tasks", fn tasks ->
      Enum.map(tasks, fn task ->
        if task["id"] == id,
          do: Map.put(task, "outcome", "A materially changed task outcome."),
          else: task
      end)
    end)
  end

  defp begin! do
    goal = CobblerHelpers.create_goal!()
    revision = propose_and_approve!(goal)
    assert {:ok, _} = request(goal, revision)
    {goal, revision, dispatch!(goal)}
  end

  defp accept!(goal, run) do
    complete_run!(goal, run.run_id)

    assert {:ok, %{disposition: :accepted}} =
             Cobbler.complete_plan_task_run(goal.id, run.run_id, exec_opts())
  end

  defp pending_request(goal, revision) do
    task =
      %Shoestring.Trajectory.Task{id: Ecto.UUID.generate(), goal_id: goal.id}
      |> Shoestring.Trajectory.Task.changeset(%{"title" => "Pending plan task"})
      |> Repo.insert!()

    request = Shoestring.Test.ElvesHelpers.run_request(goal, task)

    %{
      request
      | extensions: %{
          "shoestring.plan:binding" => %{
            "revision_number" => revision.revision_number,
            "plan_digest" => revision.digest,
            "plan_task_id" => "alpha",
            "attempt" => 1
          }
        }
    }
  end

  test "a new proposal cannot rewrite an accepted task contract" do
    {goal, _, alpha} = begin!()
    accept!(goal, alpha)

    assert {:error, {:accepted_task_contract_changed, "alpha"}} =
             proposal(goal, changed(chain_plan(), "alpha"), 1, "unsafe-edit")

    assert {:ok, %{revision: safe}} =
             proposal(goal, changed(chain_plan(), "beta"), 1, "safe-edit")

    assert safe.status == "proposed"
    assert Plans.authority(goal.id).revision_number == 1

    assert {:ok, %{accepted: ["alpha"], total_attempts: 1}} =
             Cobbler.plan_execution_status(goal.id)
  end

  test "approval rechecks evidence accepted after the proposal was written" do
    {goal, _, alpha} = begin!()

    assert {:ok, %{revision: proposed}} =
             proposal(goal, changed(chain_plan(), "alpha"), 1, "early-edit")

    accept!(goal, alpha)

    attrs =
      PlanFixtures.approve_attrs(proposed.revision_number, proposed.digest,
        decision_id: "unsafe-approval"
      )

    result = Plans.approve(goal.id, attrs, now: now(), publish_fun: fn _ -> :ok end)
    assert {:error, {:accepted_task_contract_changed, "alpha"}} = result

    assert Plans.authority(goal.id).revision_number == 1
    assert Plans.get_revision(goal.id, proposed.revision_number).status == "proposed"
  end

  test "activation rechecks evidence accepted after a superseding approval" do
    {goal, _, alpha} = begin!()

    assert {:ok, %{revision: proposed}} =
             proposal(goal, changed(chain_plan(), "alpha"), 1, "approved-early")

    approve!(goal, proposed)
    accept!(goal, alpha)
    assert {:error, {:accepted_task_contract_changed, "alpha"}} = request(goal, proposed)

    assert {:ok, %{execution: %{revision_number: 1}, total_attempts: 1}} =
             Cobbler.plan_execution_status(goal.id)
  end

  test "an amendment requires approval and carries accepted evidence and spent attempts" do
    {goal, _, alpha} = begin!()
    accept!(goal, alpha)
    beta = dispatch!(goal)
    complete_run!(goal, beta.run_id)

    assert {:ok, %{retry_state: "retry"}} =
             Cobbler.complete_plan_task_run(
               goal.id,
               beta.run_id,
               exec_opts(gate_runner_opts: gate_opts(exit_status: 1))
             )

    assert {:ok, before} = Cobbler.plan_execution_status(goal.id)

    accepted_event =
      Repo.one!(
        from e in Shoestring.Trajectory.TrajectoryEvent,
          where:
            e.goal_id == ^goal.id and e.run_id == ^alpha.run_id and
              e.type == "cobbler.plan.task.accepted"
      )

    assert before.total_attempts == 2

    assert {:ok, %{revision: proposed}} =
             proposal(goal, changed(chain_plan(), "beta"), 1, "amend-beta")

    assert {:error, {:authority_mismatch, _}} = request(goal, proposed)
    approve!(goal, proposed)
    assert {:ok, %{outcome: :recorded}} = request(goal, proposed)
    assert {:ok, carried} = Cobbler.plan_execution_status(goal.id)
    assert carried.execution.revision_number == 2
    assert carried.accepted == ["alpha"]
    assert Repo.get!(Shoestring.Trajectory.TrajectoryEvent, accepted_event.id) == accepted_event
    assert carried.total_attempts == before.total_attempts
    assert carried.total_gate_duration_ms == before.total_gate_duration_ms
    assert carried.attempts == %{"alpha" => 1, "beta" => 1}
    retry = dispatch!(goal)
    assert retry.plan_task_id == "beta"
    assert retry.attempt == 2
    assert retry.run_id != beta.run_id
    accept!(goal, retry)

    assert {:ok, %{disposition: :completed}} =
             Cobbler.advance_plan_execution(goal.id, exec_opts())

    assert {:ok, %{completed?: true, total_attempts: 3, accepted: ["alpha", "beta"]}} =
             Cobbler.plan_execution_status(goal.id)

    assert {:ok, %{consistent?: true}} = Plans.rebuild(goal.id)
    assert run_count(goal.id) == 3
  end

  test "an unresolved task cannot be replaced by approving and activating another revision" do
    {goal, _, alpha} = begin!()

    assert {:ok, %{revision: proposed}} =
             proposal(goal, changed(chain_plan(), "beta"), 1, "while-active")

    approve!(goal, proposed)
    assert {:error, :active_plan_execution} = request(goal, proposed)

    assert {:ok, %{active_task: "alpha", total_attempts: 1}} =
             Cobbler.plan_execution_status(goal.id)

    assert Repo.get!(Shoestring.Harness.RunRecord, alpha.run_id).status == "requested"
    assert run_count(goal.id) == 1
  end

  test "one amendment activation is bounded and a further approval cannot replace its authority" do
    {goal, _, alpha} = begin!()
    accept!(goal, alpha)

    assert {:ok, %{revision: second}} =
             proposal(goal, changed(chain_plan(), "beta"), 1, "amend-first")

    approve!(goal, second)
    assert {:ok, _} = request(goal, second)
    assert {:ok, %{outcome: :replayed}} = request(goal, second)
    assert {:ok, %{revision: third}} = proposal(goal, chain_plan(), 2, "amend-second")

    attrs =
      PlanFixtures.approve_attrs(third.revision_number, third.digest,
        decision_id: "approve-third"
      )

    result = Plans.approve(goal.id, attrs, now: now(), publish_fun: fn _ -> :ok end)
    assert {:error, :amendment_execution_limit} = result

    assert Plans.authority(goal.id).revision_number == 2

    assert {:ok, %{execution: %{revision_number: 2}, total_attempts: 1}} =
             Cobbler.plan_execution_status(goal.id)
  end

  test "task gate evidence has canonical run and task lineage" do
    {goal, _, alpha} = begin!()
    accept!(goal, alpha)

    events =
      Repo.all(
        from e in Shoestring.Trajectory.TrajectoryEvent,
          where:
            e.goal_id == ^goal.id and
              e.type in ["cobbler.plan.task.dispatched", "cobbler.plan.task.accepted"]
      )

    assert length(events) == 2
    run = Repo.get!(Shoestring.Harness.RunRecord, alpha.run_id)
    assert Enum.all?(events, &(&1.run_id == run.id and &1.task_id == run.task_id))
  end

  test "activation refuses a durable plan intent before its dispatch bookkeeping event" do
    goal = CobblerHelpers.create_goal!()
    revision = propose_and_approve!(goal)
    assert {:ok, _} = request(goal, revision)
    intent = pending_request(goal, revision)
    result = Shoestring.Harness.Runs.request(intent, Shoestring.Harness.Fake.identity())
    assert {:ok, run} = result

    assert {:ok, %{active_task: nil}} = Cobbler.plan_execution_status(goal.id)
    assert {:ok, %{revision: next}} = proposal(goal, changed(chain_plan(), "beta"), 1, "gap")
    approve!(goal, next)
    assert {:error, :active_plan_execution} = request(goal, next)
    assert Repo.get!(Shoestring.Harness.RunRecord, run.id).status == "requested"
    assert run_count(goal.id) == 1
  end

  test "supersession refuses new intent creation but permits recovery of an existing intent" do
    goal = CobblerHelpers.create_goal!()
    revision = propose_and_approve!(goal)
    intent = pending_request(goal, revision)
    result = Shoestring.Harness.Runs.request(intent, Shoestring.Harness.Fake.identity())
    assert {:ok, original} = result

    assert {:ok, %{revision: next}} =
             proposal(goal, changed(chain_plan(), "beta"), 1, "late-intent")

    approve!(goal, next)
    result = Shoestring.Harness.Runs.request(intent, Shoestring.Harness.Fake.identity())
    assert {:ok, recovered} = result
    assert recovered.id == original.id

    fresh = %{intent | dispatch_id: Ecto.UUID.generate()}
    result = Shoestring.Harness.Runs.request(fresh, Shoestring.Harness.Fake.identity())
    assert {:error, :plan_authority_changed} = result
    assert run_count(goal.id) == 1
  end
end
