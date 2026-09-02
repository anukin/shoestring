defmodule Shoestring.Harness.RunsTest do
  use Shoestring.DataCase, async: false

  alias Elixir.Task, as: AsyncTask
  alias Shoestring.Harness.{Error, Identity, RunRecord, RunRequest, Runs}
  alias Shoestring.Repo
  alias Shoestring.Trajectory.{Goal, Task, TrajectoryEvent}

  @goal_id "00000000-0000-4000-8000-000000000601"
  @task_id "00000000-0000-4000-8000-000000000602"
  @run_id "00000000-0000-4000-8000-000000000603"
  @dispatch_id "00000000-0000-4000-8000-000000000604"
  @other_goal_id "00000000-0000-4000-8000-000000000605"
  @other_task_id "00000000-0000-4000-8000-000000000606"

  test "reconcile repairs only missing canonical run.requested intents" do
    goal = insert_goal()
    task = insert_task(goal)
    request = run_request(goal, task)

    run =
      %RunRecord{id: @run_id}
      |> RunRecord.intent_changeset(request, "test.adapter", Shoestring.Test.FixedClock.now())
      |> Repo.insert!()

    assert {:ok, 1} = Runs.reconcile(goal.id, clock: Shoestring.Test.FixedClock)

    assert %TrajectoryEvent{} =
             Repo.get_by(TrajectoryEvent,
               goal_id: goal.id,
               run_id: run.id,
               type: "run.requested",
               idempotency_key: "run-requested:#{@dispatch_id}"
             )

    assert {:ok, 0} = Runs.reconcile(goal.id, clock: Shoestring.Test.FixedClock)
  end

  test "reconcile does not backfill a late request event for a projected run" do
    goal = insert_goal()
    task = insert_task(goal)

    run =
      %RunRecord{id: @run_id}
      |> RunRecord.intent_changeset(
        run_request(goal, task),
        "test.adapter",
        Shoestring.Test.FixedClock.now()
      )
      |> Repo.insert!()
      |> then(fn run ->
        run
        |> RunRecord.projection_changeset(%{
          status: "running",
          projection_sequence: 2,
          updated_at: Shoestring.Test.FixedClock.now()
        })
        |> Repo.update!()
      end)

    assert {:ok, 0} = Runs.reconcile(goal.id, clock: Shoestring.Test.FixedClock)
    refute Repo.exists?(from event in TrajectoryEvent, where: event.run_id == ^run.id)
  end

  test "owned? confines a run to its canonical goal" do
    goal = insert_goal()
    task = insert_task(goal)

    assert {:ok, run} =
             Runs.request(run_request(goal, task), identity(),
               clock: Shoestring.Test.FixedClock,
               identifier: Shoestring.Test.FixedIdentifier
             )

    assert Runs.owned?(goal.id, run.id, Repo)
    refute Runs.owned?("00000000-0000-4000-8000-000000000605", run.id, Repo)
    refute Runs.owned?(goal.id, "00000000-0000-4000-8000-000000000606", Repo)
  end

  test "a duplicate dispatch_id is returned as a changeset error" do
    goal = insert_goal()
    task = insert_task(goal)
    request = run_request(goal, task)

    assert {:ok, _run} =
             Runs.request(request, identity(),
               clock: Shoestring.Test.FixedClock,
               identifier: Shoestring.Test.FixedIdentifier
             )

    assert {:error, changeset} =
             %RunRecord{id: @run_id}
             |> RunRecord.intent_changeset(
               request,
               "test.adapter",
               Shoestring.Test.FixedClock.now()
             )
             |> Repo.insert()

    assert {:dispatch_id, {_message, opts}} = List.keyfind(changeset.errors, :dispatch_id, 0)
    assert opts[:constraint] == :unique
    assert opts[:constraint_name] == "harness_runs_dispatch_id_index"
  end

  test "a dispatch id collision across goals is typed and cannot disclose or append foreign data" do
    goal_a = insert_goal()
    task_a = insert_task(goal_a)
    goal_b = insert_goal(@other_goal_id)
    task_b = insert_task(goal_b, @other_task_id)

    assert {:ok, run} =
             Runs.request(
               run_request(goal_a, task_a, prompt: "goal A secret"),
               identity(),
               identifier: Shoestring.Test.FixedIdentifier,
               clock: Shoestring.Test.FixedClock
             )

    Repo.delete_all(
      from event in TrajectoryEvent,
        where: event.goal_id == ^goal_a.id and event.run_id == ^run.id
    )

    assert {:error,
            %Error{
              category: :task_failed,
              code: "dispatch_id_conflict",
              details: %{"shoestring.harness:dispatch_id" => @dispatch_id}
            } = error} =
             Runs.request(
               run_request(goal_b, task_b, prompt: "goal B secret"),
               identity(),
               identifier: Shoestring.Test.AlternateFixedIdentifier,
               clock: Shoestring.Test.FixedClock
             )

    refute inspect(error) =~ "goal B secret"
    refute Repo.exists?(from candidate in RunRecord, where: candidate.goal_id == ^goal_b.id)
    refute Repo.exists?(from event in TrajectoryEvent, where: event.goal_id == ^goal_b.id)

    refute Repo.exists?(
             from event in TrajectoryEvent, where: event.payload["prompt"] == "goal B secret"
           )

    refute Repo.exists?(
             from event in TrajectoryEvent, where: event.payload["prompt"] == "goal A secret"
           )
  end

  test "recovered request events use the persisted run identity and payload" do
    goal = insert_goal()
    task = insert_task(goal)

    assert {:ok, run} =
             Runs.request(
               run_request(goal, task, prompt: "canonical prompt"),
               identity(),
               identifier: Shoestring.Test.FixedIdentifier,
               clock: Shoestring.Test.FixedClock
             )

    Repo.delete_all(
      from event in TrajectoryEvent,
        where: event.goal_id == ^goal.id and event.run_id == ^run.id
    )

    assert {:ok, recovered} =
             Runs.request(
               run_request(goal, task, prompt: "foreign caller prompt"),
               identity(),
               identifier: Shoestring.Test.AlternateFixedIdentifier,
               clock: Shoestring.Test.FixedClock
             )

    assert recovered.id == run.id

    assert %TrajectoryEvent{payload: %{"prompt" => "canonical prompt"}} =
             Repo.get_by(TrajectoryEvent,
               goal_id: goal.id,
               run_id: run.id,
               type: "run.requested"
             )

    refute Repo.exists?(
             from event in TrajectoryEvent,
               where: event.payload["prompt"] == "foreign caller prompt"
           )
  end

  test "concurrent duplicate requests recover the single inserted run" do
    goal = insert_goal()
    task = insert_task(goal)
    request = run_request(goal, task)
    parent = self()

    task_supervisor =
      start_supervised!({AsyncTask.Supervisor, name: :runs_duplicate_task_supervisor})

    tasks =
      for identifier <- [
            Shoestring.Test.FixedIdentifier,
            Shoestring.Test.AlternateFixedIdentifier
          ] do
        AsyncTask.Supervisor.async_nolink(task_supervisor, fn ->
          send(parent, {:runs_request_ready, self()})

          receive do
            :start_request ->
              Runs.request(request, identity(),
                clock: Shoestring.Test.FixedClock,
                identifier: identifier
              )
          end
        end)
      end

    ready_pids =
      for _ <- 1..2 do
        assert_receive {:runs_request_ready, pid}
        pid
      end

    Enum.each(ready_pids, &send(&1, :start_request))

    assert [{:ok, first}, {:ok, second}] = Enum.map(tasks, &AsyncTask.await(&1, :infinity))
    assert first.id == second.id

    assert 1 ==
             Repo.aggregate(
               from(run in RunRecord, where: run.dispatch_id == ^@dispatch_id),
               :count
             )
  end

  defp run_request(goal, task, overrides \\ []) do
    assert {:ok, request} =
             RunRequest.new(%{
               version: 1,
               goal_id: goal.id,
               task_id: task.id,
               workspace_ref: "workspace/project",
               prompt: Keyword.get(overrides, :prompt, "Repair a durable run intent."),
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
    |> Goal.changeset(%{"title" => "Run reconciliation goal"})
    |> Ecto.Changeset.put_change(:owner_id, "00000000-0000-4000-8000-000000000607")
    |> Repo.insert!()
  end

  defp insert_task(goal, id \\ @task_id) do
    %Task{id: id}
    |> Task.changeset(%{"title" => "Run reconciliation task"})
    |> Ecto.Changeset.put_change(:goal_id, goal.id)
    |> Repo.insert!()
  end
end
