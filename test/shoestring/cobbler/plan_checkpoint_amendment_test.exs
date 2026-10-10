defmodule Shoestring.Cobbler.PlanCheckpointAmendmentTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.{Cobbler, Trajectory}
  alias Shoestring.Cobbler.{Commands, Planner, Plans}
  alias Shoestring.Harness.{CheckpointFallback, Checkpoints, Dispatches, Fake, RunRecord, Runs}
  alias Shoestring.Test.{CobblerHelpers, ElvesHelpers, PlanFixtures, PlannerFixtures}
  alias Shoestring.Trajectory.TrajectoryEvent
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

    assert {:ok, run} =
             Cobbler.advance_plan_execution(goal.id, exec_opts(admission_event_id: admission.id))

    Repo.get!(RunRecord, run.run_id)
  end

  defp begin! do
    goal = CobblerHelpers.create_goal!()
    first = propose_and_approve!(goal)
    assert {:ok, _} = request(goal, first)
    {goal, first, dispatch!(goal)}
  end

  defp checkpoint!(goal, run) do
    assert {:ok, checkpoint} =
             CheckpointFallback.build(%{
               checkpoint_id: Ecto.UUID.generate(),
               goal_id: goal.id,
               run_id: run.id,
               acceptance_criteria: ["The approved gate passes."],
               repository_revision: PlanFixtures.base_revision(),
               evidence: ["Synthetic checkpoint evidence."],
               decisions: [],
               unresolved_issues: [],
               stop_reason: "lease_exhausted",
               extensions: %{}
             })

    assert {:ok, _} = Checkpoints.record(goal.id, checkpoint, now: now())
    checkpoint
  end

  defp stop!(goal, run, type \\ "run.failed", category \\ "quota_refused") do
    payload =
      if type == "run.failed",
        do: %{"run_id" => run.id, "error_category" => category, "error_code" => "fixture_stop"},
        else: %{"run_id" => run.id}

    assert {:ok, _} =
             Trajectory.append(
               goal.id,
               %{
                 type: type,
                 schema_version: 1,
                 actor: "fixture",
                 idempotency_key: "elf-terminal:#{run.dispatch_id}",
                 occurred_at: now(),
                 payload: payload
               },
               trusted: [run_id: run.id, task_id: run.task_id]
             )
  end

  defp approve!(goal, revision) do
    assert {:ok, _} =
             Plans.approve(
               goal.id,
               PlanFixtures.approve_attrs(revision.revision_number, revision.digest,
                 decision_id: "approve-#{revision.revision_number}"
               ),
               exec_opts()
             )
  end

  defp amendment!(goal) do
    assert {:ok, %{revision: revision}} =
             Plans.propose(
               goal.id,
               PlanFixtures.propose_attrs(
                 plan: chain_plan(),
                 parent_revision_number: 1,
                 proposal_id: "checkpoint-amendment"
               ),
               exec_opts()
             )

    revision
  end

  defp continuation(goal, run, checkpoint) do
    original = ElvesHelpers.run_request(goal, Repo.get!(Shoestring.Trajectory.Task, run.task_id))

    %{
      original
      | workspace_ref: run.workspace_ref,
        extensions: run.extensions,
        continuation: %{
          checkpoint_id: checkpoint.checkpoint_id,
          next_action: checkpoint.next_action,
          decision_refs: []
        }
    }
  end

  defp supersessions(goal),
    do:
      Repo.all(
        from e in TrajectoryEvent,
          where: e.goal_id == ^goal.id and e.type == "cobbler.plan.task.superseded"
      )

  @tag :checkpoint_amendment_regression
  test "approved checkpoint amendment resolves the old attempt without accepting or redispatching it" do
    {goal, _, root} = begin!()
    checkpoint = checkpoint!(goal, root)
    stop!(goal, root)
    revision = amendment!(goal)
    assert {:error, {:authority_mismatch, _}} = request(goal, revision)
    assert supersessions(goal) == []
    approve!(goal, revision)
    assert {:ok, %{outcome: :recorded}} = request(goal, revision)
    assert run_count(goal.id) == 1
    assert {:ok, status} = Cobbler.plan_execution_status(goal.id)
    assert status.accepted == [] and status.total_attempts == 1 and status.active_task == nil
    assert [event] = supersessions(goal)
    assert event.payload["run_id"] == root.id
    assert event.payload["checkpoint_id"] == checkpoint.checkpoint_id
    assert event.payload["successor_revision_number"] == 2
    assert {:ok, %{outcome: :replayed}} = request(goal, revision)
    assert supersessions(goal) == [event]
    retry = dispatch!(goal)
    assert retry.extensions["shoestring.plan:binding"]["attempt"] == 2
    assert retry.id != root.id

    assert {:error, :plan_authority_changed} =
             Runs.request(continuation(goal, root, checkpoint), Fake.identity(), exec_opts())

    assert run_count(goal.id) == 2
    assert Repo.get!(RunRecord, root.id).extensions == root.extensions
    assert {:ok, %{consistent?: true}} = Plans.rebuild(goal.id)
  end

  @tag :checkpoint_amendment_regression
  test "model replan from a stopped checkpoint preserves accepted work and requires approval" do
    {goal, first, alpha} = begin!()
    complete_run!(goal, alpha.id)

    assert {:ok, %{disposition: :accepted}} =
             Cobbler.complete_plan_task_run(goal.id, alpha.id, exec_opts())

    beta = dispatch!(goal)
    checkpoint = checkpoint!(goal, beta)
    stop!(goal, beta)

    accepted =
      Repo.one!(
        from e in TrajectoryEvent,
          where: e.goal_id == ^goal.id and e.type == "cobbler.plan.task.accepted"
      )

    supervisor = start_supervised!(Task.Supervisor)

    opts = [
      now: now(),
      task_supervisor: supervisor,
      snapshot: PlannerFixtures.snapshot(now()),
      config: PlannerFixtures.config([{:ok, Jason.encode!(chain_plan()), 10}])
    ]

    attrs = %{
      request_key: "quota-replan",
      requested_by: "human:operator",
      reason: "Revise from the stopped quota checkpoint.",
      revision_number: first.revision_number,
      digest: first.digest
    }

    assert {:ok, _} = Planner.request_amendment(goal.id, attrs, opts)

    assert {:ok, %{request: candidate}} =
             Planner.generate_amendment(goal.id, "quota-replan", opts)

    assert candidate.state == "ready"
    assert candidate.projection["amendment"]["accepted_task_ids"] == ["alpha"]

    assert {:ok, %{revision: revision}} =
             Planner.adopt(
               goal.id,
               "quota-replan",
               %{digest: candidate.result_digest, authored_by: "human:operator"},
               opts
             )

    assert {:error, {:authority_mismatch, _}} = request(goal, revision)
    assert run_count(goal.id) == 2 and supersessions(goal) == []
    approve!(goal, revision)
    assert {:ok, _} = request(goal, revision)

    assert {:ok, %{accepted: ["alpha"], total_attempts: 2}} =
             Cobbler.plan_execution_status(goal.id)

    assert [event] = supersessions(goal)
    assert event.payload["checkpoint_id"] == checkpoint.checkpoint_id
    retry = dispatch!(goal)
    assert retry.extensions["shoestring.plan:binding"]["plan_task_id"] == "beta"
    complete_run!(goal, retry.id)

    assert {:ok, %{disposition: :accepted}} =
             Cobbler.complete_plan_task_run(goal.id, retry.id, exec_opts())

    assert {:ok, %{disposition: :completed}} =
             Cobbler.advance_plan_execution(goal.id, exec_opts())

    assert Repo.get!(TrajectoryEvent, accepted.id) == accepted
    assert Repo.get!(RunRecord, beta.id).extensions == beta.extensions
    assert Planner.get(goal.id).charged_output_tokens == 4096
    assert {:ok, %{consistent?: true}} = Planner.rebuild(goal.id)
    assert run_count(goal.id) == 3
  end

  test "a checkpoint and apparent terminal do not replace a still-registered Elf" do
    {goal, _, root} = begin!()
    checkpoint!(goal, root)
    stop!(goal, root)
    owner = self()

    pid =
      start_supervised!(
        {Task,
         fn ->
           {:ok, _} = Registry.register(Shoestring.Elves.Registry, root.id, nil)
           send(owner, {:owned_fixture, self()})

           receive do
             :stop -> :ok
           end
         end}
      )

    assert_receive {:owned_fixture, ^pid}
    revision = amendment!(goal)
    approve!(goal, revision)
    assert {:error, :active_plan_execution} = request(goal, revision)
    assert supersessions(goal) == [] and run_count(goal.id) == 1
  end

  for {name, type, category, checkpoint?} <- [
        {"missing checkpoint", "run.failed", "quota_refused", false},
        {"successful completion awaiting gates", "run.completed", nil, true},
        {"transport failure awaiting resolution", "run.failed", "transport", true},
        {"suspension without a terminal", "run.suspended", nil, true}
      ] do
    @stop_type type
    @category category
    @checkpoint checkpoint?
    test "#{name} cannot be superseded" do
      {goal, _, root} = begin!()
      if @checkpoint, do: checkpoint!(goal, root)
      stop!(goal, root, @stop_type, @category)
      revision = amendment!(goal)
      approve!(goal, revision)
      assert {:error, :active_plan_execution} = request(goal, revision)
      assert supersessions(goal) == [] and run_count(goal.id) == 1
    end
  end

  test "an undelivered continuation intent blocks amendment replacement" do
    {goal, _, root} = begin!()
    checkpoint = checkpoint!(goal, root)
    stop!(goal, root)

    assert {:ok, _child} =
             Runs.request(continuation(goal, root, checkpoint), Fake.identity(), exec_opts())

    revision = amendment!(goal)
    approve!(goal, revision)
    assert {:error, :active_plan_execution} = request(goal, revision)
    assert supersessions(goal) == [] and run_count(goal.id) == 2
  end

  test "a quota failure without the owned terminal identity cannot authorize replacement" do
    {goal, _, root} = begin!()
    checkpoint!(goal, root)

    assert {:ok, _} =
             Trajectory.append(
               goal.id,
               %{
                 type: "run.failed",
                 schema_version: 1,
                 actor: "fixture",
                 occurred_at: now(),
                 payload: %{
                   "run_id" => root.id,
                   "error_category" => "quota_refused",
                   "error_code" => "unowned_fixture"
                 }
               },
               trusted: [run_id: root.id]
             )

    revision = amendment!(goal)
    approve!(goal, revision)
    assert {:error, :active_plan_execution} = request(goal, revision)
    assert supersessions(goal) == [] and run_count(goal.id) == 1
  end

  test "multi-hop supersession uses the latest stopped descendant checkpoint" do
    {goal, _, root} = begin!()
    original = checkpoint!(goal, root)
    stop!(goal, root)

    assert {:ok, child} =
             Runs.request(continuation(goal, root, original), Fake.identity(), exec_opts())

    assert {:ok, _, _} = Dispatches.enqueue_for_run(child, exec_opts())
    latest = checkpoint!(goal, child)
    stop!(goal, child)
    claim = Commands.active_claim()
    revision = amendment!(goal)
    approve!(goal, revision)
    assert {:ok, _} = request(goal, revision)
    assert Commands.active_claim() == claim
    assert [event] = supersessions(goal)
    assert event.payload["run_id"] == child.id
    assert event.payload["checkpoint_id"] == latest.checkpoint_id
    refute event.payload["checkpoint_id"] == original.checkpoint_id
    assert {:ok, %{total_attempts: 1, accepted: []}} = Cobbler.plan_execution_status(goal.id)
    assert run_count(goal.id) == 2
  end

  test "amendment can raise a stopped task limit but cannot erase its consumed provider time" do
    {goal, _, root} = begin!()
    checkpoint!(goal, root)

    assert {:ok, _} =
             Trajectory.append(
               goal.id,
               %{
                 type: "run.starting",
                 schema_version: 1,
                 actor: "fixture",
                 occurred_at: now(),
                 payload: %{"run_id" => root.id}
               },
               trusted: [run_id: root.id]
             )

    at = DateTime.add(now(), 1201)

    assert {:ok, _} =
             Trajectory.append(
               goal.id,
               %{
                 type: "run.failed",
                 schema_version: 1,
                 actor: "fixture",
                 idempotency_key: "elf-terminal:#{root.dispatch_id}",
                 occurred_at: at,
                 payload: %{
                   "run_id" => root.id,
                   "error_category" => "quota_refused",
                   "error_code" => "fixture_stop"
                 }
               },
               trusted: [run_id: root.id]
             )

    assert {:error, :task_duration_exhausted} =
             Cobbler.resume_plan_execution(goal.id, exec_opts(now: at))

    plan =
      Map.update!(chain_plan(), "tasks", fn tasks ->
        Enum.map(tasks, fn task ->
          if task["id"] == "alpha",
            do: put_in(task, ["execution", "max_duration_seconds"], 2400),
            else: task
        end)
      end)

    assert {:ok, %{revision: revision}} =
             Plans.propose(
               goal.id,
               PlanFixtures.propose_attrs(
                 plan: plan,
                 parent_revision_number: 1,
                 proposal_id: "raise-duration"
               ),
               exec_opts()
             )

    approve!(goal, revision)
    assert {:ok, _} = request(goal, revision)
    assert {:ok, status} = Cobbler.plan_execution_status(goal.id, now: at)
    assert status.total_run_duration_ms == 1_201_000
    assert status.total_attempts == 1
    retry = dispatch!(goal)
    assert retry.extensions["shoestring.plan:binding"]["attempt"] == 2
    assert run_count(goal.id) == 2
  end

  for stop_type <- ["run.interrupted", "run.cancelled"] do
    @stop_type stop_type
    test "#{stop_type} with a checkpoint and no live owner permits approved supersession" do
      {goal, _, root} = begin!()
      checkpoint!(goal, root)
      stop!(goal, root, @stop_type)
      revision = amendment!(goal)
      approve!(goal, revision)
      assert {:ok, _} = request(goal, revision)
      assert [_] = supersessions(goal)
      assert run_count(goal.id) == 1
    end
  end
end
