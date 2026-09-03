defmodule Shoestring.Harness.DispatchesTest do
  use Shoestring.DataCase, async: false
  use Oban.Testing, repo: Shoestring.Repo, engine: Oban.Engines.Lite

  alias Elixir.Task, as: AsyncTask
  alias Oban.Job
  alias Oban.Queues.Executor
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
    previous_clock = Application.get_env(:shoestring, :dispatch_clock)
    previous_call_timeout = Application.get_env(:shoestring, :dispatch_call_timeout)
    previous_writer_opts = Application.get_env(:shoestring, :dispatch_writer_opts)

    Application.put_env(:shoestring, :dispatch_effect, Shoestring.Test.DispatchEffect)
    Application.put_env(:shoestring, :dispatch_effect_test_pid, self())
    Application.put_env(:shoestring, :dispatch_effect_test_result, :ok)
    Application.put_env(:shoestring, :dispatch_clock, Shoestring.Test.FixedClock)

    on_exit(fn ->
      restore_env(:dispatch_effect, previous_effect)
      restore_env(:dispatch_complete_effect, previous_complete_effect)
      restore_env(:dispatch_effect_test_pid, previous_pid)
      restore_env(:dispatch_effect_test_result, previous_result)
      restore_env(:dispatch_clock, previous_clock)
      restore_env(:dispatch_call_timeout, previous_call_timeout)
      restore_env(:dispatch_writer_opts, previous_writer_opts)
    end)

    goal = insert_goal()
    {:ok, goal: goal, task: insert_task(goal)}
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

  test "a delivery that loses after another claimant completes is a typed benign cancellation", %{
    goal: goal,
    task: task
  } do
    assert {:ok, _dispatch, job} = Dispatches.enqueue(run_request(goal, task), identity(), opts())

    assert :ok = perform_delivery(job)
    assert_receive {:dispatch_effect, _run_id, @dispatch_id}

    assert {:cancel, :effect_completed} = perform_delivery(job)
    refute_receive {:dispatch_effect, _run_id, @dispatch_id}
    assert %DispatchRecord{status: "effect_completed"} = Repo.get!(DispatchRecord, @dispatch_id)
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

    assert {:cancel, :effect_failed} = perform_delivery(job)
    assert_receive {:dispatch_effect, _run_id, @dispatch_id}

    assert_receive {:dispatch_outcome, [:shoestring, :harness, :dispatch_outcome], %{count: 1},
                    %{outcome: "effect_failed", error_code: "effect_failed"}}

    Application.put_env(:shoestring, :dispatch_effect_test_result, :ok)

    assert {:cancel, :effect_failed} = perform_delivery(job)
    refute_receive {:dispatch_effect, _run_id, @dispatch_id}
    refute_receive {:dispatch_outcome, _event, _measurements, _metadata}

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

    assert {:cancel, :effect_completion_not_recorded} = perform_delivery(job)

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

    assert {:cancel, :effect_outcome_unknown} = perform_delivery(job)
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

    assert {:ok, %{repaired_count: 1, failures: []}} = Dispatches.reconcile(opts())

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

  test "duplicate enqueue does not return a discarded Oban job", %{goal: goal, task: task} do
    assert {:ok, dispatch, original_job} =
             Dispatches.enqueue(run_request(goal, task), identity(), opts())

    original_job
    |> Ecto.Changeset.change(state: "discarded", discarded_at: Shoestring.Test.FixedClock.now())
    |> Repo.update!()

    assert {:ok, recovered, replacement_job} =
             Dispatches.enqueue(run_request(goal, task), identity(), opts())

    assert recovered.dispatch_id == dispatch.dispatch_id
    assert replacement_job.id != original_job.id
    assert replacement_job.state in ["available", "scheduled"]
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
    assert {:ok, %{repaired_count: 0, failures: []}} = Dispatches.reconcile(opts())
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

    assert {:cancel, :run_cancelled} = perform_delivery(job)
    refute_receive {:dispatch_effect, _run_id, @dispatch_id}

    assert %DispatchRecord{
             status: "cancelled",
             outcome_code: "run_cancelled",
             outcome_at: outcome_at
           } = Repo.get!(DispatchRecord, @dispatch_id)

    assert outcome_at == Shoestring.Test.FixedClock.now()

    assert %TrajectoryEvent{} =
             Repo.get_by(TrajectoryEvent,
               goal_id: goal.id,
               run_id: dispatch.run_id,
               type: "dispatch.cancelled",
               idempotency_key: "dispatch-cancelled:#{@dispatch_id}"
             )
  end

  test "real delivery cancels every terminal run state with one durable outcome" do
    telemetry_id = "dispatch-terminal-outcome-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      telemetry_id,
      [:shoestring, :harness, :dispatch_outcome],
      fn event, measurements, metadata, pid ->
        send(pid, {:terminal_outcome, event, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    for status <- ["cancelling", "cancelled", "completed", "failed"] do
      goal = insert_goal(Ecto.UUID.generate())
      task = insert_task(goal, Ecto.UUID.generate())
      dispatch_id = Ecto.UUID.generate()

      assert {:ok, dispatch, job} =
               Dispatches.enqueue(
                 run_request(goal, task, dispatch_id: dispatch_id),
                 identity(),
                 opts(identifier: Shoestring.Harness.SystemIdentifier)
               )

      Repo.get!(RunRecord, dispatch.run_id)
      |> RunRecord.projection_changeset(%{
        status: status,
        projection_sequence: 2,
        updated_at: Shoestring.Test.FixedClock.now()
      })
      |> Repo.update!()

      reason =
        %{
          "cancelling" => :run_cancelling,
          "cancelled" => :run_cancelled,
          "completed" => :run_completed,
          "failed" => :run_failed
        }
        |> Map.fetch!(status)

      expected_code = "run_#{status}"
      assert {:cancel, ^reason} = perform_real_delivery(job)
      refute_receive {:dispatch_effect, _run_id, ^dispatch_id}

      assert %DispatchRecord{
               status: "cancelled",
               outcome_code: outcome_code,
               outcome_at: outcome_at
             } = Repo.get!(DispatchRecord, dispatch_id)

      assert outcome_code == expected_code
      assert outcome_at == Shoestring.Test.FixedClock.now()

      assert %TrajectoryEvent{} =
               Repo.get_by(TrajectoryEvent,
                 goal_id: goal.id,
                 run_id: dispatch.run_id,
                 type: "dispatch.cancelled",
                 idempotency_key: "dispatch-cancelled:#{dispatch_id}"
               )

      assert {:cancel, ^reason} = perform_real_delivery(Repo.get!(Job, job.id))
    end

    for status <- ["cancelling", "cancelled", "completed", "failed"] do
      expected_code = "run_#{status}"

      assert_receive {:terminal_outcome, [:shoestring, :harness, :dispatch_outcome], %{count: 1},
                      %{outcome: "cancelled", error_code: ^expected_code}}
    end

    refute_receive {:terminal_outcome, _event, _measurements, _metadata}
  end

  test "reconciliation defers a requested dispatch whose job is lost after the run advances",
       %{goal: goal, task: task} do
    assert {:ok, dispatch, job} = Dispatches.enqueue(run_request(goal, task), identity(), opts())
    Repo.delete!(job)

    Repo.get!(RunRecord, dispatch.run_id)
    |> RunRecord.projection_changeset(%{
      status: "running",
      projection_sequence: 2,
      updated_at: Shoestring.Test.FixedClock.now()
    })
    |> Repo.update!()

    assert {:ok, %{repaired_count: 1, failures: []}} = Dispatches.reconcile(opts())
    assert [] = all_enqueued(worker: DispatchWorker)

    assert %DispatchRecord{
             status: "effect_deferred",
             outcome_code: "run_state_advanced",
             outcome_at: outcome_at
           } = Repo.get!(DispatchRecord, dispatch.dispatch_id)

    assert outcome_at == Shoestring.Test.FixedClock.now()
    assert {:ok, %{repaired_count: 0, failures: []}} = Dispatches.reconcile(opts())
  end

  test "worker defers every advanced run state without firing or completing an effect" do
    for status <- ["starting", "running", "pausing", "suspended"] do
      goal = insert_goal(Ecto.UUID.generate())
      task = insert_task(goal, Ecto.UUID.generate())
      dispatch_id = Ecto.UUID.generate()

      assert {:ok, dispatch, job} =
               Dispatches.enqueue(
                 run_request(goal, task, dispatch_id: dispatch_id),
                 identity(),
                 opts(identifier: Shoestring.Harness.SystemIdentifier)
               )

      Repo.get!(RunRecord, dispatch.run_id)
      |> RunRecord.projection_changeset(%{
        status: status,
        projection_sequence: 2,
        updated_at: Shoestring.Test.FixedClock.now()
      })
      |> Repo.update!()

      expected_outcome_at = Shoestring.Test.FixedClock.now()
      assert {:cancel, :effect_deferred} = perform_delivery(job)
      refute_receive {:dispatch_effect, _run_id, ^dispatch_id}

      assert %DispatchRecord{status: "effect_deferred", outcome_code: "run_state_advanced"} =
               deferred_dispatch = Repo.get!(DispatchRecord, dispatch_id)

      assert deferred_dispatch.outcome_at == expected_outcome_at

      assert %TrajectoryEvent{} =
               Repo.get_by(TrajectoryEvent,
                 goal_id: goal.id,
                 run_id: dispatch.run_id,
                 type: "dispatch.effect_deferred",
                 idempotency_key: "dispatch-effect-deferred:#{dispatch_id}"
               )

      refute Repo.exists?(
               from event in TrajectoryEvent,
                 where:
                   event.goal_id == ^goal.id and event.run_id == ^dispatch.run_id and
                     event.type == "dispatch.effect_completed"
             )
    end
  end

  test "a queued delivery rechecks the run state after reconciliation before firing" do
    goal = insert_goal(Ecto.UUID.generate())
    task = insert_task(goal, Ecto.UUID.generate())
    dispatch_id = Ecto.UUID.generate()

    assert {:ok, dispatch, job} =
             Dispatches.enqueue(
               run_request(goal, task, dispatch_id: dispatch_id),
               identity(),
               opts(identifier: Shoestring.Harness.SystemIdentifier)
             )

    assert {:ok, %{repaired_count: 0, failures: []}} =
             Dispatches.reconcile(opts(identifier: Shoestring.Harness.SystemIdentifier))

    Repo.get!(RunRecord, dispatch.run_id)
    |> RunRecord.projection_changeset(%{
      status: "running",
      projection_sequence: 2,
      updated_at: Shoestring.Test.FixedClock.now()
    })
    |> Repo.update!()

    assert {:cancel, :effect_deferred} = perform_delivery(job)
    refute_receive {:dispatch_effect, _run_id, ^dispatch_id}
    assert %DispatchRecord{status: "effect_deferred"} = Repo.get!(DispatchRecord, dispatch_id)
  end

  test "reconciliation continues after a poisoned run and repairs a healthy dispatch", %{
    goal: healthy_goal,
    task: healthy_task
  } do
    poisoned_goal = insert_goal(Ecto.UUID.generate())
    poisoned_task = insert_task(poisoned_goal, Ecto.UUID.generate())
    poisoned_dispatch_id = Ecto.UUID.generate()

    assert {:ok, poisoned_request} =
             RunRequest.new(%{
               version: 1,
               goal_id: poisoned_goal.id,
               task_id: poisoned_task.id,
               workspace_ref: "workspace/project",
               prompt: "poisoned run",
               policy: %{mode: "supervised", network: false, write_access: true},
               requested_capabilities: [],
               dispatch_id: poisoned_dispatch_id,
               extensions: %{}
             })

    poisoned_run =
      %RunRecord{id: Ecto.UUID.generate()}
      |> RunRecord.intent_changeset(
        poisoned_request,
        "test.adapter",
        Shoestring.Test.FixedClock.now()
      )
      |> Repo.insert!()

    assert {:ok, healthy_dispatch, healthy_job} =
             Dispatches.enqueue(
               run_request(healthy_goal, healthy_task),
               identity(),
               opts()
             )

    Repo.delete!(healthy_job)

    telemetry_id = "dispatch-reconcile-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      telemetry_id,
      [:shoestring, :harness, :dispatch_reconcile],
      fn event, measurements, metadata, pid ->
        send(pid, {:dispatch_reconcile, event, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    writer_opts = [attempt_fun: fn _input, _references, _state -> {:error, :poisoned_writer} end]

    reconciler =
      start_supervised!(
        {Reconciler,
         name: :poisoned_dispatch_reconciler_test,
         repo: Repo,
         clock: Shoestring.Test.FixedClock,
         identifier: Shoestring.Harness.SystemIdentifier,
         writer_opts: writer_opts}
      )

    assert %Reconciler{
             last_result: {:ok, %{repaired_count: 1, failures: [failure]}}
           } = :sys.get_state(reconciler)

    assert failure.goal_id == poisoned_goal.id
    assert failure.run_id == poisoned_run.id
    assert failure.dispatch_id == poisoned_dispatch_id
    assert failure.reason == "poisoned_writer"
    refute inspect(failure) =~ "poisoned run"

    assert %DispatchRecord{job_id: repaired_job_id} =
             Repo.get!(DispatchRecord, healthy_dispatch.dispatch_id)

    assert repaired_job_id
    assert Repo.get!(Job, repaired_job_id).state in ["available", "scheduled"]

    assert_receive {:dispatch_reconcile, [:shoestring, :harness, :dispatch_reconcile],
                    %{repaired_count: 1, failure_count: 1},
                    %{
                      result: :ok,
                      failures: [%{reason: "poisoned_writer"}]
                    }}
  end

  test "terminal dispatches remain idempotent after completed jobs are pruned" do
    for status <- ["effect_completed", "effect_failed", "effect_unknown", "cancelled"] do
      goal = insert_goal(Ecto.UUID.generate())
      task = insert_task(goal, Ecto.UUID.generate())
      dispatch_id = Ecto.UUID.generate()

      assert {:ok, dispatch, job} =
               Dispatches.enqueue(
                 run_request(goal, task, dispatch_id: dispatch_id),
                 identity(),
                 opts(identifier: Shoestring.Harness.SystemIdentifier)
               )

      terminal_dispatch =
        case status do
          status when status in ["effect_failed", "effect_unknown"] ->
            DispatchRecord.outcome_changeset(
              dispatch,
              status,
              Shoestring.Test.FixedClock.now()
            )

          status ->
            DispatchRecord.status_changeset(dispatch, status, Shoestring.Test.FixedClock.now())
        end

      Repo.update!(terminal_dispatch)
      Repo.delete!(job)

      assert {:ok, recovered, nil} =
               Dispatches.enqueue(
                 run_request(goal, task, dispatch_id: dispatch_id),
                 identity(),
                 opts(identifier: Shoestring.Harness.SystemIdentifier)
               )

      assert recovered.dispatch_id == dispatch_id
      assert recovered.status == status
      assert is_nil(recovered.job_id)
      refute Repo.exists?(from candidate in Job, where: candidate.id == ^job.id)
    end
  end

  test "adapter failure details never reach worker results or Oban errors", %{
    goal: goal,
    task: task
  } do
    assert {:ok, _dispatch, job} = Dispatches.enqueue(run_request(goal, task), identity(), opts())
    secret = "credential=super-secret prompt=/private/project"
    Application.put_env(:shoestring, :dispatch_effect_test_result, {:error, secret})

    assert {:cancel, :effect_failed} = perform_delivery(job)
    refute inspect({:cancel, :effect_failed}) =~ secret

    oban_job =
      %{
        Repo.get!(Job, job.id)
        | unsaved_error: %{
            kind: :error,
            reason: Oban.PerformError.exception({DispatchWorker, {:cancel, :effect_failed}}),
            stacktrace: []
          }
      }

    assert :ok = Oban.Engines.Lite.cancel_job(Oban.config(), oban_job)
    refute inspect(Repo.get!(Job, job.id).errors) =~ secret
  end

  test "real executor sanitizes a writer timeout before persisting Oban errors", %{
    goal: goal,
    task: task
  } do
    prompt = "prompt=sentinel credential=secret-token"
    credential_path = "workspace/private/project"

    assert {:ok, _dispatch, job} =
             Dispatches.enqueue(
               run_request(goal, task, prompt: prompt, workspace_ref: credential_path),
               identity(),
               opts()
             )

    Repo.delete_all(from event in TrajectoryEvent, where: event.goal_id == ^goal.id)
    stop_writer(goal.id)

    test_pid = self()

    Application.put_env(:shoestring, :dispatch_call_timeout, 1)

    Application.put_env(:shoestring, :dispatch_writer_opts,
      attempt_fun: fn input, _references, _state ->
        send(test_pid, {:writer_blocked, self(), input})

        receive do
          :release_writer -> {:error, :released}
        end
      end
    )

    result_task =
      AsyncTask.async(fn ->
        perform_real_delivery(job)
      end)

    assert_receive {:writer_blocked, writer_pid, %Shoestring.Trajectory.AppendInput{} = input}
    assert input.payload["prompt"] == prompt
    assert input.payload["workspace_ref"] == credential_path

    assert {:error, :dispatch_delivery_failed} = AsyncTask.await(result_task, :infinity)

    errors = Repo.get!(Job, job.id).errors |> inspect()
    refute errors =~ prompt
    refute errors =~ "secret-token"
    refute errors =~ credential_path
    refute errors =~ "AppendInput"
    refute errors =~ "timeout"
    refute errors =~ "released"
    assert errors =~ "dispatch_delivery_failed"

    send(writer_pid, :release_writer)
    stop_writer(goal.id)
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

    assert {:ok, %{repaired_count: 0, failures: []}} = Dispatches.reconcile(opts())
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

    assert {:ok, %{repaired_count: 0, failures: []}} = Dispatches.reconcile(opts())
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

    assert %Reconciler{last_result: {:ok, %{repaired_count: 1, failures: []}}} =
             :sys.get_state(reconciler)

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

    assert %Reconciler{last_result: {:ok, %{repaired_count: 1, failures: []}}} =
             :sys.get_state(reconciler)

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

    assert {:ok, %{repaired_count: 0, failures: []}} = Dispatches.reconcile(opts())
    run_id = run.id
    refute Repo.exists?(from dispatch in DispatchRecord, where: dispatch.run_id == ^run_id)
    assert [] = all_enqueued(worker: DispatchWorker)
  end

  defp opts(overrides \\ []) do
    [clock: Shoestring.Test.FixedClock, identifier: Shoestring.Test.FixedIdentifier]
    |> Keyword.merge(overrides)
  end

  defp run_request(goal, task, overrides \\ []) do
    assert {:ok, request} =
             RunRequest.new(%{
               version: 1,
               goal_id: goal.id,
               task_id: task.id,
               workspace_ref: Keyword.get(overrides, :workspace_ref, "workspace/project"),
               prompt: Keyword.get(overrides, :prompt, "Dispatch a deterministic fake run."),
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

  defp insert_goal(id \\ @goal_id) do
    %Goal{id: id}
    |> Goal.changeset(%{"title" => "Dispatch goal"})
    |> Ecto.Changeset.put_change(:owner_id, "00000000-0000-4000-8000-000000000504")
    |> Repo.insert!()
  end

  defp insert_task(goal, id \\ @task_id) do
    %Task{id: id}
    |> Task.changeset(%{"title" => "Dispatch task"})
    |> Ecto.Changeset.put_change(:goal_id, goal.id)
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

  defp perform_real_delivery(job) do
    job =
      job
      |> Map.put(:attempted_at, Shoestring.Test.FixedClock.now())
      |> Map.put(:scheduled_at, Shoestring.Test.FixedClock.now())

    Oban.config()
    |> Executor.new(job, safe: false, ack: true)
    |> Executor.call()
    |> Map.fetch!(:result)
  end

  defp stop_writer(goal_id) do
    case Registry.lookup(Shoestring.Trajectory.WriterRegistry, goal_id) do
      [{writer_pid, _value}] ->
        monitor_ref = Process.monitor(writer_pid)

        assert :ok =
                 DynamicSupervisor.terminate_child(
                   Shoestring.Trajectory.WriterSupervisor,
                   writer_pid
                 )

        assert_receive {:DOWN, ^monitor_ref, :process, ^writer_pid, _reason}

      [] ->
        :ok
    end
  end
end
