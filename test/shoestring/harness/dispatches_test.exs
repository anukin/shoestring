defmodule Shoestring.Harness.DispatchesTest do
  use Shoestring.DataCase, async: false
  use Oban.Testing, repo: Shoestring.Repo, engine: Oban.Engines.Lite

  alias Elixir.Task, as: AsyncTask
  alias Oban.Job
  alias Shoestring.Harness.{DispatchRecord, DispatchWorker, Identity, RunRecord, RunRequest, Runs}
  alias Shoestring.Harness.Dispatch.Reconciler
  alias Shoestring.Harness.Dispatches
  alias Shoestring.Repo
  alias Shoestring.Trajectory.{Goal, Task, TrajectoryEvent}

  @goal_id "00000000-0000-4000-8000-000000000501"
  @task_id "00000000-0000-4000-8000-000000000502"
  @dispatch_id "00000000-0000-4000-8000-000000000503"
  @preexisting_run_id "00000000-0000-4000-8000-000000000505"

  setup do
    previous_effect = Application.get_env(:shoestring, :dispatch_effect)
    previous_complete_effect = Application.get_env(:shoestring, :dispatch_complete_effect)
    previous_pid = Application.get_env(:shoestring, :dispatch_effect_test_pid)
    previous_result = Application.get_env(:shoestring, :dispatch_effect_test_result)

    Application.put_env(:shoestring, :dispatch_effect, Shoestring.Test.DispatchEffect)
    Application.put_env(:shoestring, :dispatch_effect_test_pid, self())
    Application.put_env(:shoestring, :dispatch_effect_test_result, :ok)

    on_exit(fn ->
      restore_env(:dispatch_effect, previous_effect)
      restore_env(:dispatch_complete_effect, previous_complete_effect)
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

  test "concurrent duplicate enqueue calls converge on one durable dispatch and job", %{
    goal: goal,
    task: task
  } do
    request = run_request(goal, task)
    id = identity()
    parent = self()

    task_supervisor =
      start_supervised!({AsyncTask.Supervisor, name: :dispatches_duplicate_task_supervisor})

    tasks =
      for identifier <- [
            Shoestring.Test.FixedIdentifier,
            Shoestring.Test.AlternateFixedIdentifier
          ] do
        AsyncTask.Supervisor.async_nolink(task_supervisor, fn ->
          send(parent, {:enqueue_ready, self()})

          receive do
            :start_enqueue -> Dispatches.enqueue(request, id, opts(identifier: identifier))
          end
        end)
      end

    ready_pids =
      for _ <- 1..2 do
        assert_receive {:enqueue_ready, pid}
        pid
      end

    Enum.each(ready_pids, &send(&1, :start_enqueue))

    assert [{:ok, first, first_job}, {:ok, second, second_job}] =
             Enum.map(tasks, &AsyncTask.await(&1, :infinity))

    assert first.dispatch_id == second.dispatch_id
    assert first.run_id == second.run_id
    assert first_job.id == second_job.id
    assert 1 == Repo.aggregate(from(dispatch in DispatchRecord), :count)
    assert 1 == Repo.aggregate(from(run in RunRecord), :count)
    assert [_job] = all_enqueued(worker: DispatchWorker)
  end

  test "enqueue rolls back a run when dispatch persistence fails", %{goal: goal, task: task} do
    other_run_id = "00000000-0000-4000-8000-000000000599"

    %RunRecord{id: other_run_id}
    |> RunRecord.intent_changeset(
      run_request(goal, task, dispatch_id: "00000000-0000-4000-8000-000000000598"),
      "test.adapter",
      Shoestring.Test.FixedClock.now()
    )
    |> Repo.insert!()

    %DispatchRecord{dispatch_id: @dispatch_id}
    |> Ecto.Changeset.change(
      goal_id: goal.id,
      task_id: task.id,
      run_id: other_run_id,
      request_version: 1,
      status: "requested",
      inserted_at: Shoestring.Test.FixedClock.now(),
      updated_at: Shoestring.Test.FixedClock.now()
    )
    |> Repo.insert!()

    assert {:error, _reason} = Dispatches.enqueue(run_request(goal, task), identity(), opts())
    refute Repo.exists?(from(run in RunRecord, where: run.dispatch_id == ^@dispatch_id))
    assert 1 == Repo.aggregate(from(dispatch in DispatchRecord), :count)
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

    telemetry_id = "dispatch-outcome-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      telemetry_id,
      [:shoestring, :harness, :dispatch_outcome],
      fn event, measurements, metadata, pid ->
        send(pid, {:dispatch_outcome, event, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    Application.put_env(:shoestring, :dispatch_effect_test_result, {:error, :scripted_failure})

    assert {:error, {:effect_failed, :scripted_failure}} = perform_delivery(job)
    assert_receive {:dispatch_effect, _run_id, @dispatch_id}

    assert_receive {:dispatch_outcome, [:shoestring, :harness, :dispatch_outcome], %{count: 1},
                    %{outcome: "effect_failed", error_code: "effect_failed"}}

    Application.put_env(:shoestring, :dispatch_effect_test_result, :ok)

    assert {:error, {:effect_failed, :already_recorded}} = perform_delivery(job)
    refute_receive {:dispatch_effect, _run_id, @dispatch_id}

    assert %DispatchRecord{status: "effect_failed", outcome_code: "effect_failed"} =
             Repo.get!(DispatchRecord, @dispatch_id)

    assert %TrajectoryEvent{} =
             Repo.get_by(TrajectoryEvent,
               goal_id: goal.id,
               type: "dispatch.effect_failed",
               idempotency_key: "dispatch-effect-failed:#{@dispatch_id}"
             )
  end

  test "a completion write failure records an unknown outcome and never reports success", %{
    goal: goal,
    task: task
  } do
    assert {:ok, _dispatch, job} = Dispatches.enqueue(run_request(goal, task), identity(), opts())

    Application.put_env(:shoestring, :dispatch_complete_effect, fn _dispatch_id ->
      {:error, :completion_write_failed}
    end)

    assert {:error, {:effect_completion_not_recorded, :completion_write_failed}} =
             perform_delivery(job)

    assert_receive {:dispatch_effect, _run_id, @dispatch_id}

    assert %DispatchRecord{
             status: "effect_unknown",
             outcome_code: "effect_unknown",
             outcome_at: outcome_at
           } = Repo.get!(DispatchRecord, @dispatch_id)

    assert outcome_at

    assert %TrajectoryEvent{} =
             Repo.get_by(TrajectoryEvent,
               goal_id: goal.id,
               type: "dispatch.effect_unknown",
               idempotency_key: "dispatch-effect-unknown:#{@dispatch_id}"
             )

    Application.delete_env(:shoestring, :dispatch_complete_effect)

    assert {:error, {:effect_outcome_unknown, :operator_review_required}} = perform_delivery(job)
    refute_receive {:dispatch_effect, _run_id, @dispatch_id}
  end

  test "reconciliation repairs a dead discarded job without reusing its delivery", %{
    goal: goal,
    task: task
  } do
    assert {:ok, dispatch, original_job} =
             Dispatches.enqueue(run_request(goal, task), identity(), opts())

    original_job
    |> Ecto.Changeset.change(state: "discarded", discarded_at: Shoestring.Test.FixedClock.now())
    |> Repo.update!()

    assert {:ok, 1} = Dispatches.reconcile(opts())

    assert %DispatchRecord{job_id: repaired_job_id} =
             repaired_dispatch = Repo.get!(DispatchRecord, dispatch.dispatch_id)

    assert repaired_job_id != original_job.id
    assert %Job{state: repaired_state} = Repo.get!(Job, repaired_job_id)
    assert repaired_state in ["available", "scheduled"]
    assert :ok = perform_delivery(Repo.get!(Job, repaired_job_id))
    run_id = dispatch.run_id
    assert_receive {:dispatch_effect, ^run_id, @dispatch_id}
    assert repaired_dispatch.status == "requested"
  end

  test "lifeline rescues an orphaned executing job without creating another delivery", %{
    goal: goal,
    task: task
  } do
    assert {:ok, dispatch, job} = Dispatches.enqueue(run_request(goal, task), identity(), opts())

    job
    |> Ecto.Changeset.change(
      state: "executing",
      attempted_at: DateTime.add(Shoestring.Test.FixedClock.now(), -600, :second)
    )
    |> Repo.update!()

    assert {:ok, rescued_jobs} =
             Oban.Engine.rescue_jobs(Oban.config(), Job, rescue_after: 0)

    assert Enum.any?(rescued_jobs, &(&1.id == job.id))
    assert %Job{state: rescued_state} = Repo.get!(Job, job.id)
    assert rescued_state in ["available", "scheduled"]
    assert {:ok, 0} = Dispatches.reconcile(opts())
    assert :ok = perform_delivery(Repo.get!(Job, job.id))
    run_id = dispatch.run_id
    assert_receive {:dispatch_effect, ^run_id, @dispatch_id}
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

  test "reconciliation ignores a pre-existing projected running run", %{goal: goal, task: task} do
    run =
      %RunRecord{id: @preexisting_run_id}
      |> RunRecord.intent_changeset(
        run_request(goal, task),
        "test.adapter",
        Shoestring.Test.FixedClock.now()
      )
      |> Repo.insert!()
      |> RunRecord.projection_changeset(%{
        status: "running",
        projection_sequence: 2,
        updated_at: Shoestring.Test.FixedClock.now()
      })
      |> Repo.update!()

    assert {:ok, 0} = Dispatches.reconcile(opts())
    refute Repo.exists?(from dispatch in DispatchRecord, where: dispatch.run_id == ^run.id)
    assert [] = all_enqueued(worker: DispatchWorker)
  end

  test "reconciliation skips a terminal dispatch even when its job is gone", %{
    goal: goal,
    task: task
  } do
    assert {:ok, dispatch, job} = Dispatches.enqueue(run_request(goal, task), identity(), opts())

    dispatch
    |> DispatchRecord.status_changeset("effect_completed", Shoestring.Test.FixedClock.now())
    |> Repo.update!()

    Repo.delete!(job)

    assert {:ok, 0} = Dispatches.reconcile(opts())
    assert [] = all_enqueued(worker: DispatchWorker)
    assert %DispatchRecord{status: "effect_completed"} = Repo.get!(DispatchRecord, @dispatch_id)
  end

  test "the boot reconciler surfaces repo failures without entering a crash loop" do
    reconciler =
      start_supervised!({Reconciler, name: :failed_dispatch_reconciler_test, repo: nil})

    _ = :sys.get_state(reconciler)

    assert %Reconciler{last_result: {:error, :dispatch_reconciliation_failed}} =
             :sys.get_state(reconciler)

    assert {:error, :dispatch_reconciliation_failed} = Reconciler.reconcile_now(reconciler)
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

  test "restart reconciliation repairs a run intent stranded before dispatch and job insertion",
       %{
         goal: goal,
         task: task
       } do
    assert {:ok, run} = Runs.request(run_request(goal, task), identity(), opts())
    assert nil == Repo.get(DispatchRecord, run.dispatch_id)
    assert [] = all_enqueued(worker: DispatchWorker)

    reconciler =
      start_supervised!(
        {Reconciler,
         name: :run_intent_orphan_reconciler_test, repo: Repo, clock: Shoestring.Test.FixedClock}
      )

    assert %Reconciler{last_result: {:ok, 1}} = :sys.get_state(reconciler)
    assert [%Job{id: job_id}] = all_enqueued(worker: DispatchWorker)

    run_id = run.id

    assert %DispatchRecord{dispatch_id: @dispatch_id, run_id: ^run_id, job_id: ^job_id} =
             Repo.get!(DispatchRecord, @dispatch_id)
  end

  test "restart reconciliation repairs a requested run whose projection already advanced", %{
    goal: goal,
    task: task
  } do
    assert {:ok, run} = Runs.request(run_request(goal, task), identity(), opts())

    run
    |> RunRecord.projection_changeset(%{
      status: "requested",
      projection_sequence: 4,
      updated_at: Shoestring.Test.FixedClock.now()
    })
    |> Repo.update!()

    assert {:ok, 1} = Dispatches.reconcile(opts())
    run_id = run.id
    assert %DispatchRecord{run_id: ^run_id} = Repo.get!(DispatchRecord, @dispatch_id)
    assert [%Job{}] = all_enqueued(worker: DispatchWorker)
  end

  defp opts(overrides \\ []) do
    [
      clock: Shoestring.Test.FixedClock,
      identifier: Keyword.get(overrides, :identifier, Shoestring.Test.FixedIdentifier)
    ]
  end

  defp run_request(goal, task, overrides \\ []) do
    assert {:ok, request} =
             RunRequest.new(%{
               version: 1,
               goal_id: goal.id,
               task_id: task.id,
               workspace_ref: "workspace/project",
               prompt: "Dispatch a deterministic fake run.",
               policy: %{mode: "supervised", network: false, write_access: true},
               requested_capabilities: [],
               dispatch_id: Keyword.get(overrides, :dispatch_id, @dispatch_id),
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
