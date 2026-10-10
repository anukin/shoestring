defmodule Shoestring.Cobbler.PlanRetirementTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.Cobbler
  alias Shoestring.Cobbler.{PlanContract, Plans}
  alias Shoestring.Test.{CobblerHelpers, PlanFixtures}
  import Shoestring.Test.PlanExecutorHelpers, except: [independent_plan: 0]

  defp retire(plan, id, reason \\ "The reviewed goal no longer requires this work.") do
    Map.put(plan, "retirements", [%{"task_id" => id, "reason" => reason}])
  end

  defp independent_plan do
    Map.update!(
      chain_plan(),
      "tasks",
      &Enum.map(&1, fn task -> Map.put(task, "depends_on", []) end)
    )
  end

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

    assert {:ok, run} =
             Cobbler.advance_plan_execution(goal.id, exec_opts(admission_event_id: admission.id))

    run
  end

  defp begin!(plan \\ chain_plan()) do
    goal = CobblerHelpers.create_goal!()
    revision = propose_and_approve!(goal, plan)
    assert {:ok, _} = request(goal, revision)
    {goal, Plans.get_revision(goal.id, revision.revision_number), dispatch!(goal)}
  end

  defp propose!(goal, plan, parent \\ 1, key \\ "retire-beta") do
    assert {:ok, %{revision: revision}} =
             Plans.propose(
               goal.id,
               PlanFixtures.propose_attrs(
                 plan: plan,
                 parent_revision_number: parent,
                 proposal_id: key
               ),
               exec_opts()
             )

    revision
  end

  defp approve(goal, revision) do
    Plans.approve(
      goal.id,
      PlanFixtures.approve_attrs(revision.revision_number, revision.digest,
        decision_id: "approve-retirement-#{revision.revision_number}"
      ),
      exec_opts()
    )
  end

  defp accept!(goal, run) do
    complete_run!(goal, run.run_id)

    assert {:ok, %{disposition: :accepted}} =
             Cobbler.complete_plan_task_run(goal.id, run.run_id, exec_opts())
  end

  @tag :retirement_capability
  test "approved retirement skips failed work while retaining contracts, evidence and counters" do
    {goal, first, alpha} = begin!()
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

    revision = propose!(goal, retire(chain_plan(), "beta"))
    assert {:error, {:authority_mismatch, _}} = request(goal, revision)
    assert Plans.authority(goal.id).revision_number == 1
    assert {:ok, _} = approve(goal, revision)
    assert {:ok, _} = request(goal, revision)

    assert {:ok, %{disposition: :completed}} =
             Cobbler.advance_plan_execution(goal.id, exec_opts())

    assert {:ok, status} = Cobbler.plan_execution_status(goal.id)
    assert status.completed?
    assert status.accepted == ["alpha"]
    assert status.total_tasks == 1
    assert status.total_attempts == before.total_attempts
    assert status.total_gate_duration_ms == before.total_gate_duration_ms + 7
    assert status.retirements == revision.content["retirements"]
    assert revision.content["tasks"] == first.content["tasks"]
    assert Plans.get_revision(goal.id, 1).content == first.content
    assert run_count(goal.id) == 2
    assert {:ok, %{consistent?: true}} = Plans.rebuild(goal.id)
  end

  test "retirement cannot replace an unresolved active task" do
    {goal, _, alpha} = begin!(independent_plan())
    revision = propose!(goal, retire(independent_plan(), "alpha"))
    assert {:ok, _} = approve(goal, revision)
    assert {:error, :active_plan_execution} = request(goal, revision)
    assert {:ok, %{active_run_id: id}} = Cobbler.plan_execution_status(goal.id)
    assert id == alpha.run_id
    assert run_count(goal.id) == 1
  end

  test "a retired task binding cannot allocate a provider run directly" do
    goal = CobblerHelpers.create_goal!()
    propose_and_approve!(goal)
    revision = propose!(goal, retire(chain_plan(), "beta"))
    assert {:ok, _} = approve(goal, revision)

    task =
      %Shoestring.Trajectory.Task{id: Ecto.UUID.generate(), goal_id: goal.id}
      |> Shoestring.Trajectory.Task.changeset(%{"title" => "Retired fixture task"})
      |> Repo.insert!()

    original = Shoestring.Test.ElvesHelpers.run_request(goal, task)

    request = %{
      original
      | extensions: %{
          "shoestring.plan:binding" => %{
            "revision_number" => revision.revision_number,
            "plan_digest" => revision.digest,
            "plan_task_id" => "beta",
            "attempt" => 1
          }
        }
    }

    assert {:error, :plan_task_retired} =
             Shoestring.Harness.Runs.request(
               request,
               Shoestring.Harness.Fake.identity(),
               exec_opts()
             )

    assert run_count(goal.id) == 0
  end

  for boundary <- [:proposal, :approval, :activation] do
    @boundary boundary
    test "new evidence prevents retiring an accepted task at #{boundary}" do
      assert_accepted_protection(@boundary)
    end
  end

  defp assert_accepted_protection(boundary) do
    {goal, _, alpha} = begin!(independent_plan())
    plan = retire(independent_plan(), "alpha")
    revision = if boundary != :proposal, do: propose!(goal, plan)
    if boundary == :activation, do: assert({:ok, _} = approve(goal, revision))
    accept!(goal, alpha)

    result =
      case boundary do
        :proposal ->
          Plans.propose(
            goal.id,
            PlanFixtures.propose_attrs(
              plan: plan,
              parent_revision_number: 1,
              proposal_id: "retire-accepted"
            ),
            exec_opts()
          )

        :approval ->
          approve(goal, revision)

        :activation ->
          request(goal, revision)
      end

    assert result == {:error, {:accepted_task_retired, "alpha"}}
    assert run_count(goal.id) == 1
    assert {:ok, %{accepted: ["alpha"]}} = Cobbler.plan_execution_status(goal.id)
  end

  test "retirement requires an approved identity and retains its reviewed contract and reason" do
    goal = CobblerHelpers.create_goal!()

    assert {:error, {:retirement_without_approved_task, "beta"}} =
             Plans.propose(
               goal.id,
               PlanFixtures.propose_attrs(plan: retire(chain_plan(), "beta")),
               exec_opts()
             )

    binding = propose_and_approve!(goal)
    first = Plans.get_revision(goal.id, binding.revision_number)

    changed =
      Map.update!(chain_plan(), "tasks", fn tasks ->
        Enum.map(tasks, fn task ->
          if task["id"] == "beta",
            do: Map.put(task, "outcome", "Changed retired contract"),
            else: task
        end)
      end)

    assert {:error, {:retired_task_contract_changed, "beta"}} =
             Plans.propose(
               goal.id,
               PlanFixtures.propose_attrs(
                 plan: retire(changed, "beta"),
                 parent_revision_number: 1,
                 proposal_id: "changed-retired"
               ),
               exec_opts()
             )

    second = propose!(goal, retire(first.content, "beta"))
    assert {:ok, _} = approve(goal, second)

    for plan <- [chain_plan(), retire(chain_plan(), "beta", "A different reason")] do
      assert {:error, :approved_retirement_changed} =
               Plans.propose(
                 goal.id,
                 PlanFixtures.propose_attrs(
                   plan: plan,
                   parent_revision_number: 2,
                   proposal_id: "undo-retirement"
                 ),
                 exec_opts()
               )
    end
  end

  test "retirement validation rejects ambiguous scope and preserves historical digests" do
    assert {:ok, original} = PlanContract.new(chain_plan())
    refute Map.has_key?(original.content, "retirements")

    assert {:ok, replayed} =
             PlanContract.from_canonical_json(PlanContract.canonical_json(original))

    assert replayed.digest == original.digest
    assert {:ok, contract} = PlanContract.new(retire(chain_plan(), "beta"))
    assert contract.digest != original.digest
    assert PlanContract.task_ids(contract) == ["alpha", "beta"]
    assert PlanContract.required_task_ids(contract) == ["alpha"]

    for entries <- [
          [%{"task_id" => "alpha", "reason" => "Still required by beta"}],
          [%{"task_id" => "missing", "reason" => "No such task"}],
          [%{"task_id" => "beta", "reason" => ""}],
          [%{"task_id" => "beta", "reason" => "One"}, %{"task_id" => "beta", "reason" => "Two"}],
          [%{"task_id" => "alpha", "reason" => "All"}, %{"task_id" => "beta", "reason" => "All"}],
          [%{"task_id" => "beta", "reason" => "Reason", "extra" => true}]
        ] do
      assert {:error, {:invalid_plan, _}} =
               PlanContract.new(Map.put(chain_plan(), "retirements", entries))
    end
  end
end
