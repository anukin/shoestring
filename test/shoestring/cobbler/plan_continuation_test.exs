defmodule Shoestring.Cobbler.PlanContinuationTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.{Cobbler, Repo, Trajectory}
  alias Shoestring.Cobbler.Plans
  alias Shoestring.Harness.{CheckpointFallback, Checkpoints, Dispatches, Fake, RunRecord, Runs}
  alias Shoestring.Test.{CobblerHelpers, ElvesHelpers, PlanFixtures}
  import Shoestring.Test.PlanExecutorHelpers

  defp begin! do
    goal = CobblerHelpers.create_goal!()
    revision = propose_and_approve!(goal)
    admission = admit!(goal)

    assert {:ok, _} =
             Cobbler.request_plan_execution(
               goal.id,
               %{revision_number: 1, digest: revision.digest, admission_event_id: admission.id},
               exec_opts()
             )

    assert {:ok, dispatched} =
             Cobbler.advance_plan_execution(goal.id, exec_opts(admission_event_id: admission.id))

    run = Repo.get!(RunRecord, dispatched.run_id)
    {goal, run, checkpoint!(goal, run)}
  end

  defp checkpoint!(goal, run) do
    assert {:ok, checkpoint} =
             CheckpointFallback.build(%{
               checkpoint_id: Ecto.UUID.generate(),
               goal_id: goal.id,
               run_id: run.id,
               acceptance_criteria: ["The approved task gate passes."],
               repository_revision: PlanFixtures.base_revision(),
               evidence: ["Synthetic checkpoint evidence"],
               decisions: [],
               unresolved_issues: [],
               stop_reason: "lease_exhausted",
               extensions: %{}
             })

    assert {:ok, _} = Checkpoints.record(goal.id, checkpoint, now: now())
    checkpoint
  end

  defp stop!(goal, run, category \\ "quota_refused") do
    assert {:ok, _} =
             Trajectory.append(
               goal.id,
               %{
                 "type" => "run.failed",
                 "schema_version" => 1,
                 "actor" => "fixture",
                 "occurred_at" => now(),
                 "payload" => %{
                   "run_id" => run.id,
                   "error_category" => category,
                   "error_code" => "rate_limit_exceeded"
                 }
               },
               trusted: [run_id: run.id, task_id: run.task_id]
             )
  end

  defp continue!(goal, parent, checkpoint, overrides \\ %{}, deliver? \\ true) do
    request = continuation_request(goal, parent, checkpoint, overrides)
    assert {:ok, child} = Runs.request(request, Fake.identity(), exec_opts())

    if deliver?, do: assert({:ok, _, _} = Dispatches.enqueue_for_run(child, exec_opts()))
    child
  end

  defp continuation_request(goal, parent, checkpoint, overrides) do
    task = Repo.get!(Shoestring.Trajectory.Task, parent.task_id)
    request = ElvesHelpers.run_request(goal, task)

    Map.merge(request, %{
      workspace_ref: parent.workspace_ref,
      extensions: parent.extensions,
      continuation: %{
        checkpoint_id: checkpoint.checkpoint_id,
        next_action: checkpoint.next_action,
        decision_refs: []
      }
    })
    |> Map.merge(overrides)
  end

  @tag :plan_continuation_regression
  test "completed continuation unlocks the dependent without charging another task attempt" do
    {goal, root, checkpoint} = begin!()
    stop!(goal, root)
    child = continue!(goal, root, checkpoint)
    complete_run!(goal, child.id)
    admission = admit!(goal)

    assert {:ok, %{disposition: :dispatched, plan_task_id: "beta"}} =
             Cobbler.resume_plan_execution(goal.id, exec_opts(admission_event_id: admission.id))

    assert {:ok,
            %{accepted: ["alpha"], attempts: %{"alpha" => 1, "beta" => 1}, total_attempts: 2}} =
             Cobbler.plan_execution_status(goal.id)
  end

  @tag :plan_continuation_regression
  test "accepted continuation resolves all ancestor runs before amendment activation" do
    {goal, root, checkpoint} = begin!()
    stop!(goal, root)
    child = continue!(goal, root, checkpoint)
    complete_run!(goal, child.id)

    assert {:ok, %{disposition: :accepted}} =
             Cobbler.complete_plan_task_run(goal.id, child.id, exec_opts())

    assert {:ok, %{revision: proposed}} =
             Plans.propose(
               goal.id,
               PlanFixtures.propose_attrs(
                 plan: chain_plan(),
                 parent_revision_number: 1,
                 proposal_id: "after-continuation"
               ),
               exec_opts()
             )

    assert {:ok, _} =
             Plans.approve(
               goal.id,
               PlanFixtures.approve_attrs(2, proposed.digest, decision_id: "approve-2"),
               exec_opts()
             )

    admission = admit!(goal)

    assert {:ok, _} =
             Cobbler.request_plan_execution(
               goal.id,
               %{revision_number: 2, digest: proposed.digest, admission_event_id: admission.id},
               exec_opts()
             )

    assert {:ok, %{accepted: ["alpha"], total_attempts: 1}} =
             Cobbler.plan_execution_status(goal.id)
  end

  test "a request without durable delivery does not replace the active run" do
    {goal, root, checkpoint} = begin!()
    stop!(goal, root)
    child = continue!(goal, root, checkpoint, %{}, false)
    complete_run!(goal, child.id)

    assert {:ok, %{disposition: :awaiting_task, active_run_id: id}} =
             Cobbler.resume_plan_execution(goal.id, exec_opts())

    assert id == root.id
    assert {:ok, %{accepted: [], total_attempts: 1}} = Cobbler.plan_execution_status(goal.id)
  end

  @tag :plan_continuation_regression
  test "multiple quota continuations keep one attempt and old intent replay remains idempotent" do
    {goal, root, checkpoint} = begin!()
    stop!(goal, root)
    child = continue!(goal, root, checkpoint)
    child_checkpoint = checkpoint!(goal, child)
    stop!(goal, child)
    grandchild = continue!(goal, child, child_checkpoint)

    assert {:ok, %{total_attempts: 1} = before} =
             Cobbler.plan_execution_status(goal.id)

    request = continuation_request(goal, root, checkpoint, %{dispatch_id: child.dispatch_id})
    assert {:ok, replayed} = Runs.request(request, Fake.identity(), exec_opts())
    assert replayed.id == child.id
    assert run_count(goal.id) == 3
    complete_run!(goal, grandchild.id)

    assert {:ok, %{disposition: :accepted}} =
             Cobbler.complete_plan_task_run(goal.id, grandchild.id, exec_opts())

    assert before.active_run_ids == [root.id, child.id, grandchild.id]

    assert {:ok, %{accepted: ["alpha"], total_attempts: 1}} =
             Cobbler.plan_execution_status(goal.id)
  end

  @tag :plan_continuation_regression
  test "a changed attempt binding is refused before intent creation" do
    {goal, root, checkpoint} = begin!()
    stop!(goal, root)
    extensions = put_in(root.extensions, ["shoestring.plan:binding", "attempt"], 2)

    assert {:error, :plan_continuation_binding_mismatch} =
             Runs.request(
               continuation_request(goal, root, checkpoint, %{extensions: extensions}),
               Fake.identity(),
               exec_opts()
             )

    assert run_count(goal.id) == 1
  end

  @tag :plan_continuation_regression
  test "a continuation cannot replace a parent which has not stopped" do
    {goal, root, checkpoint} = begin!()

    assert {:error, :plan_continuation_parent_not_stopped} =
             Runs.request(
               continuation_request(goal, root, checkpoint, %{}),
               Fake.identity(),
               exec_opts()
             )

    assert run_count(goal.id) == 1
  end

  @tag :plan_continuation_regression
  test "two continuation branches cannot silently choose a winner" do
    {goal, root, checkpoint} = begin!()
    stop!(goal, root)
    continue!(goal, root, checkpoint)

    assert {:error, :ambiguous_plan_continuation} =
             Runs.request(
               continuation_request(goal, root, checkpoint, %{}),
               Fake.identity(),
               exec_opts()
             )

    assert run_count(goal.id) == 2
  end

  @tag :plan_continuation_regression
  test "continuation cannot bypass an already recorded task failure" do
    {goal, root, checkpoint} = begin!()
    stop!(goal, root, "transport")

    assert {:ok, %{disposition: :gate_failed}} =
             Cobbler.complete_plan_task_run(goal.id, root.id, exec_opts())

    assert {:error, :plan_attempt_already_resolved} =
             Runs.request(
               continuation_request(goal, root, checkpoint, %{}),
               Fake.identity(),
               exec_opts()
             )

    assert run_count(goal.id) == 1
  end

  @tag :plan_continuation_regression
  test "continuation cannot switch workspaces" do
    {goal, root, checkpoint} = begin!()
    stop!(goal, root)

    assert {:error, :plan_continuation_binding_mismatch} =
             Runs.request(
               continuation_request(goal, root, checkpoint, %{workspace_ref: "workspace/foreign"}),
               Fake.identity(),
               exec_opts()
             )

    assert run_count(goal.id) == 1
  end

  test "continuation cannot introduce a different agent binding" do
    {goal, root, checkpoint} = begin!()
    stop!(goal, root)

    extensions =
      Map.put(root.extensions, "shoestring.agent:binding", %{"model" => "fixture-other"})

    assert {:error, :invalid_execution_profile} =
             Runs.request(
               continuation_request(goal, root, checkpoint, %{extensions: extensions}),
               Fake.identity(),
               exec_opts()
             )

    assert run_count(goal.id) == 1
  end
end
