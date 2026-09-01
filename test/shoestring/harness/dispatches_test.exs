defmodule Shoestring.Harness.DispatchesTest do
  use Shoestring.DataCase, async: false
  use Oban.Testing, repo: Shoestring.Repo, engine: Oban.Engines.Lite

  alias Oban.Job
  alias Shoestring.Harness.{DispatchRecord, DispatchWorker, Identity, RunRecord, RunRequest}
  alias Shoestring.Harness.Dispatch.Reconciler
  alias Shoestring.Harness.Dispatches
  alias Shoestring.Repo
  alias Shoestring.Trajectory.{Goal, Task, TrajectoryEvent}

  @goal_id "00000000-0000-4000-8000-000000000501"
  @task_id "00000000-0000-4000-8000-000000000502"
  @dispatch_id "00000000-0000-4000-8000-000000000503"

  setup do
    previous_effect = Application.get_env(:shoestring, :dispatch_effect)
    previous_pid = Application.get_env(:shoestring, :dispatch_effect_test_pid)
    previous_result = Application.get_env(:shoestring, :dispatch_effect_test_result)

    Application.put_env(:shoestring, :dispatch_effect, Shoestring.Test.DispatchEffect)
    Application.put_env(:shoestring, :dispatch_effect_test_pid, self())
    Application.put_env(:shoestring, :dispatch_effect_test_result, :ok)

    on_exit(fn ->
      restore_env(:dispatch_effect, previous_effect)
      restore_env(:dispatch_effect_test_pid, previous_pid)
      restore_env(:dispatch_effect_test_result, previous_result)
    end)

    {:ok, goal: insert_goal(), task: insert_task()}
  end

  test "persists a canonical versioned dispatch intent and atomically links one delivery job", %{
    goal: goal,
    task: task
  } do
    assert {:ok, dispatch, job} = Dispatches.enqueue(run_request(goal, task), identity(), opts())

    assert dispatch.dispatch_id == @dispatch_id
    assert dispatch.status == "requested"
    assert dispatch.job_id == job.id
    assert job.args["dispatch_id"] == @dispatch_id
    assert job.worker == "Shoestring.Harness.DispatchWorker"

    assert %TrajectoryEvent{schema_version: 1, payload: payload} =
             Repo.get_by(TrajectoryEvent,
               goal_id: goal.id,
               type: "dispatch.requested",
               idempotency_key: "dispatch-requested:#{@dispatch_id}"
             )

    assert payload == %{
             "dispatch_id" => @dispatch_id,
             "request_version" => 1,
             "run_id" => dispatch.run_id
           }
  end

  test "duplicate intent and enqueue return the same durable delivery without another job", %{
    goal: goal,
    task: task
  } do
    assert {:ok, first, first_job} =
             Dispatches.enqueue(run_request(goal, task), identity(), opts())

    assert {:ok, second, second_job} =
             Dispatches.enqueue(run_request(goal, task), identity(), opts())

    assert second.dispatch_id == first.dispatch_id
    assert second_job.id == first_job.id
    assert [_job] = all_enqueued(worker: DispatchWorker)

    assert 1 ==
             Repo.aggregate(
               from(event in TrajectoryEvent,
                 where: event.goal_id == ^goal.id and event.type == "dispatch.requested"
               ),
               :count
             )
  end

  test "manual delivery invokes one effect and does not accept the run or task", %{
    goal: goal,
    task: task
  } do
    assert {:ok, dispatch, job} = Dispatches.enqueue(run_request(goal, task), identity(), opts())

    assert :ok = perform_delivery(job)
    run_id = dispatch.run_id
    assert_receive {:dispatch_effect, ^run_id, @dispatch_id}

    assert %DispatchRecord{status: "effect_completed"} = Repo.get!(DispatchRecord, @dispatch_id)
    assert %RunRecord{status: "requested"} = Repo.get!(RunRecord, dispatch.run_id)
    assert %Task{status: "pending"} = Repo.get!(Task, task.id)
  end

  test "worker reconciles missing canonical run and dispatch intent before invoking an effect", %{
    goal: goal,
    task: task
  } do
    assert {:ok, dispatch, job} = Dispatches.enqueue(run_request(goal, task), identity(), opts())

    Repo.delete_all(
      from(event in TrajectoryEvent,
        where:
          event.goal_id == ^goal.id and
            event.idempotency_key in [
              ^"run-requested:#{@dispatch_id}",
              ^"dispatch-requested:#{@dispatch_id}"
            ]
      )
    )

    assert :ok = perform_delivery(job)
    run_id = dispatch.run_id
    assert_receive {:dispatch_effect, ^run_id, @dispatch_id}

    assert 1 ==
             Repo.aggregate(
               from(event in TrajectoryEvent,
                 where:
                   event.goal_id == ^goal.id and
                     event.idempotency_key == ^"run-requested:#{@dispatch_id}"
               ),
               :count
             )

    assert 1 ==
             Repo.aggregate(
               from(event in TrajectoryEvent,
                 where:
                   event.goal_id == ^goal.id and
                     event.idempotency_key == ^"dispatch-requested:#{@dispatch_id}"
               ),
               :count
             )
  end

  test "duplicate delivery and retry never repeat an already claimed logical effect", %{
    goal: goal,
    task: task
  } do
    assert {:ok, _dispatch, job} = Dispatches.enqueue(run_request(goal, task), identity(), opts())

    Application.put_env(:shoestring, :dispatch_effect_test_result, {:error, :scripted_failure})

    assert {:error, {:effect_failed, :scripted_failure}} = perform_delivery(job)
    assert_receive {:dispatch_effect, _run_id, @dispatch_id}

    Application.put_env(:shoestring, :dispatch_effect_test_result, :ok)

    assert :ok = perform_delivery(job)
    assert :ok = perform_delivery(job)
    refute_receive {:dispatch_effect, _run_id, @dispatch_id}

    assert %DispatchRecord{status: "effect_started"} = Repo.get!(DispatchRecord, @dispatch_id)
  end

  test "a cancelled run cancels delivery before any effect", %{goal: goal, task: task} do
    assert {:ok, dispatch, job} = Dispatches.enqueue(run_request(goal, task), identity(), opts())

    Repo.get!(RunRecord, dispatch.run_id)
    |> RunRecord.projection_changeset(%{
      status: "cancelled",
      projection_sequence: 1,
      updated_at: Shoestring.Test.FixedClock.now()
    })
    |> Repo.update!()

    assert :ok = perform_delivery(job)
    refute_receive {:dispatch_effect, _run_id, @dispatch_id}
    assert %DispatchRecord{status: "cancelled"} = Repo.get!(DispatchRecord, @dispatch_id)
  end

  test "a restart reconciliation repairs durable intent whose linked job is missing", %{
    goal: goal,
    task: task
  } do
    assert {:ok, dispatch, job} = Dispatches.enqueue(run_request(goal, task), identity(), opts())
    Repo.delete!(job)

    reconciler =
      start_supervised!(
        {Reconciler,
         name: :dispatch_reconciler_test, repo: Repo, clock: Shoestring.Test.FixedClock}
      )

    assert %Reconciler{last_result: {:ok, 1}} = :sys.get_state(reconciler)
    assert [%Job{id: repaired_job_id}] = all_enqueued(worker: DispatchWorker)

    assert %DispatchRecord{job_id: ^repaired_job_id} =
             Repo.get!(DispatchRecord, dispatch.dispatch_id)
  end

  defp opts do
    [
      clock: Shoestring.Test.FixedClock,
      identifier: Shoestring.Test.FixedIdentifier
    ]
  end

  defp run_request(goal, task) do
    assert {:ok, request} =
             RunRequest.new(%{
               version: 1,
               goal_id: goal.id,
               task_id: task.id,
               workspace_ref: "workspace/project",
               prompt: "Dispatch a deterministic fake run.",
               policy: %{mode: "supervised", network: false, write_access: true},
               requested_capabilities: [],
               dispatch_id: @dispatch_id,
               extensions: %{}
             })

    request
  end

  defp identity do
    assert {:ok, identity} =
             Identity.new(%{
               adapter_id: "test.adapter",
               provider: "test",
               adapter_version: "1.0.0",
               schema_version: 1,
               invocation_mode: :fake
             })

    identity
  end

  defp insert_goal do
    %Goal{id: @goal_id}
    |> Goal.changeset(%{"title" => "Dispatch goal"})
    |> Ecto.Changeset.put_change(:owner_id, "00000000-0000-4000-8000-000000000504")
    |> Repo.insert!()
  end

  defp insert_task do
    %Task{id: @task_id}
    |> Task.changeset(%{"title" => "Dispatch task"})
    |> Ecto.Changeset.put_change(:goal_id, @goal_id)
    |> Repo.insert!()
  end

  defp restore_env(key, nil), do: Application.delete_env(:shoestring, key)
  defp restore_env(key, value), do: Application.put_env(:shoestring, key, value)

  defp perform_delivery(job) do
    job
    |> Map.put(:attempted_at, Shoestring.Test.FixedClock.now())
    |> Map.put(:scheduled_at, Shoestring.Test.FixedClock.now())
    |> perform_job()
  end
end
