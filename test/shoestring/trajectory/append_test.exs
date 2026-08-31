defmodule Shoestring.Trajectory.AppendTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.Repo
  alias Shoestring.Harness.RunRecord
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{Goal, TrajectoryEvent}
  alias Shoestring.Trajectory.Task, as: TrajectoryTask

  test "the public append boundary assigns trusted identity and ordering fields" do
    goal = insert_goal()
    forged_id = Ecto.UUID.generate()

    input =
      valid_input()
      |> Map.merge(%{
        "id" => forged_id,
        "goal_id" => Ecto.UUID.generate(),
        "sequence" => 900,
        "task_id" => Ecto.UUID.generate(),
        "run_id" => Ecto.UUID.generate(),
        "parent_event_id" => Ecto.UUID.generate()
      })

    assert {:error, {:forbidden_append_fields, fields}} = Trajectory.append(goal.id, input)

    assert Enum.sort(fields) == [
             "goal_id",
             "id",
             "parent_event_id",
             "run_id",
             "sequence",
             "task_id"
           ]

    assert Repo.aggregate(TrajectoryEvent, :count, :id) == 0

    assert {:ok, event} = Trajectory.append(goal.id, valid_input())
    assert event.id != forged_id
    assert event.goal_id == goal.id
    assert event.sequence == 1
    assert event.task_id == nil
    assert event.run_id == nil
    assert event.parent_event_id == nil
  end

  test "concurrent appends to one goal are lossless and contiguous" do
    goal = insert_goal()
    count = 40

    results =
      Task.async_stream(
        1..count,
        fn number -> Trajectory.append(goal.id, valid_input("decision-#{number}")) end,
        max_concurrency: 20,
        timeout: :infinity
      )
      |> Enum.to_list()

    events = for {:ok, {:ok, event}} <- results, do: event
    assert length(events) == count
    assert Enum.sort(Enum.map(events, & &1.sequence)) == Enum.to_list(1..count)
    assert Repo.aggregate(TrajectoryEvent, :count, :id) == count
  end

  test "concurrent startup registers exactly one writer for a goal" do
    goal = insert_goal()

    results =
      Task.async_stream(
        1..20,
        fn number -> Trajectory.append(goal.id, valid_input("startup-#{number}")) end,
        max_concurrency: 20,
        timeout: :infinity
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, _event}}, &1))
    assert [{pid, _value}] = Registry.lookup(Shoestring.Trajectory.WriterRegistry, goal.id)
    assert is_pid(pid)
  end

  test "an idle shutdown queued before dispatch is recovered without killing the caller" do
    goal = insert_goal()
    dispatches = :counters.new(1, [])

    dispatch_fun = fn pid, request, timeout ->
      dispatch_number = :counters.get(dispatches, 1)
      :counters.add(dispatches, 1, 1)

      if dispatch_number == 0 do
        %{idle_token: token} = :sys.get_state(pid)
        send(pid, {:idle_timeout, token})
      end

      GenServer.call(pid, request, timeout)
    end

    assert {:ok, event} =
             Trajectory.append(goal.id, valid_input("idle-race"),
               writer_opts: [idle_timeout: 60_000],
               dispatch_fun: dispatch_fun
             )

    assert event.sequence == 1
    assert :counters.get(dispatches, 1) == 2
  end

  test "a second expected writer disappearance returns a stable error" do
    goal = insert_goal()
    dispatches = :counters.new(1, [])

    dispatch_fun = fn pid, request, timeout ->
      :counters.add(dispatches, 1, 1)
      exit({:noproc, {GenServer, :call, [pid, request, timeout]}})
    end

    assert {:error, {:writer_unavailable, :disappeared}} =
             Trajectory.append(goal.id, valid_input("double-writer-disappearance"),
               writer_opts: [idle_timeout: :infinity],
               dispatch_fun: dispatch_fun
             )

    assert :counters.get(dispatches, 1) == 2
    assert Repo.aggregate(TrajectoryEvent, :count, :id) == 0
    stop_writer(goal.id)
  end

  test "an ambiguous shutdown is not retried for a non-idempotent append" do
    goal = insert_goal()
    dispatches = :counters.new(1, [])

    dispatch_fun = fn pid, request, timeout ->
      :counters.add(dispatches, 1, 1)
      exit({:shutdown, {GenServer, :call, [pid, request, timeout]}})
    end

    assert {:error, {:writer_unavailable, :ambiguous}} =
             Trajectory.append(goal.id, valid_input("ambiguous-shutdown"),
               writer_opts: [idle_timeout: :infinity],
               dispatch_fun: dispatch_fun
             )

    assert :counters.get(dispatches, 1) == 1
    assert Repo.aggregate(TrajectoryEvent, :count, :id) == 0
    stop_writer(goal.id)
  end

  test "a busy writer for one goal does not block another goal" do
    first_goal = insert_goal()
    second_goal = insert_goal()

    always_busy = fn _input, _references, _state -> {:error, :busy} end

    assert {:error, {:retry_exhausted, :busy}} =
             Trajectory.append(first_goal.id, valid_input(),
               writer_opts: [attempt_fun: always_busy, max_retries: 1]
             )

    assert {:ok, event} = Trajectory.append(second_goal.id, valid_input())
    assert event.goal_id == second_goal.id
    assert event.sequence == 1
  end

  test "a duplicate idempotency key stores and publishes exactly once" do
    goal = insert_goal()
    topic = Trajectory.topic(goal.id)
    :ok = Phoenix.PubSub.subscribe(Shoestring.PubSub, topic)
    input = valid_input("duplicate-key")

    assert {:ok, first} = Trajectory.append(goal.id, input)
    assert_receive {:trajectory_event_committed, ^first}
    assert {:ok, second} = Trajectory.append(goal.id, input)
    assert second.id == first.id
    refute_receive {:trajectory_event_committed, _event}, 50
    assert Repo.aggregate(TrajectoryEvent, :count, :id) == 1
  end

  test "concurrent duplicate idempotency keys store and publish exactly once" do
    goal = insert_goal()
    topic = Trajectory.topic(goal.id)
    :ok = Phoenix.PubSub.subscribe(Shoestring.PubSub, topic)
    count = 20

    results =
      Task.async_stream(
        1..count,
        fn _number -> Trajectory.append(goal.id, valid_input("concurrent-duplicate")) end,
        max_concurrency: count,
        timeout: :infinity
      )
      |> Enum.to_list()

    events = for {:ok, {:ok, event}} <- results, do: event
    assert length(events) == count
    assert events |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 1
    assert_receive {:trajectory_event_committed, published}
    assert published.id == hd(events).id
    refute_receive {:trajectory_event_committed, _event}, 50
    assert Repo.aggregate(TrajectoryEvent, :count, :id) == 1
  end

  test "trusted domain references are persisted while raw attrs remain forbidden" do
    goal = insert_goal()
    task = insert_task(goal)
    assert {:ok, parent} = Trajectory.append(goal.id, valid_input("trusted-parent"))
    run = insert_run(goal, task)

    assert {:ok, event} =
             Trajectory.append(goal.id, valid_input("trusted-references"),
               trusted: [task_id: task.id, run_id: run.id, parent_event_id: parent.id]
             )

    assert event.task_id == task.id
    assert event.run_id == run.id
    assert event.parent_event_id == parent.id

    assert {:error, {:forbidden_append_fields, _fields}} =
             Trajectory.append(
               goal.id,
               Map.put(valid_input("forged-references"), "task_id", task.id)
             )
  end

  test "trusted task references must belong to the appended goal" do
    goal = insert_goal()
    other_goal = insert_goal()
    other_task = insert_task(other_goal)

    assert {:error, {:trusted_reference_not_owned, :task_id}} =
             Trajectory.append(goal.id, valid_input("wrong-task-owner"),
               trusted: [task_id: other_task.id]
             )

    assert {:ok, foreign_parent} = Trajectory.append(other_goal.id, valid_input("foreign-parent"))

    assert {:error, {:trusted_reference_not_owned, :parent_event_id}} =
             Trajectory.append(goal.id, valid_input("wrong-parent-owner"),
               trusted: [parent_event_id: foreign_parent.id]
             )

    assert {:ok, []} = Trajectory.replay(goal.id)
  end

  test "invalid and unknown events store and publish nothing" do
    goal = insert_goal()
    topic = Trajectory.topic(goal.id)
    :ok = Phoenix.PubSub.subscribe(Shoestring.PubSub, topic)

    assert {:error, {:invalid_payload, "task.created", 1, _changeset}} =
             Trajectory.append(goal.id, %{
               "type" => "task.created",
               "schema_version" => 1,
               "actor" => "system",
               "payload" => %{"task_id" => "not-a-uuid", "title" => "bad"}
             })

    assert {:error, {:unknown_event_type, "future.event"}} =
             Trajectory.append(goal.id, %{
               "type" => "future.event",
               "schema_version" => 1,
               "actor" => "system",
               "payload" => %{}
             })

    refute_receive {:trajectory_event_committed, _event}, 50
    assert Repo.aggregate(TrajectoryEvent, :count, :id) == 0
    assert Registry.lookup(Shoestring.Trajectory.WriterRegistry, goal.id) == []
  end

  test "a committed event remains replayable when publication fails" do
    goal = insert_goal()
    publish_failure = fn _pubsub, _topic, _message -> {:error, :pubsub_unavailable} end

    assert {:error, {:publish_failed, :pubsub_unavailable, committed}} =
             Trajectory.append(goal.id, valid_input("publish-failure"),
               writer_opts: [publish_fun: publish_failure]
             )

    assert {:ok, [replayed]} = Trajectory.replay(goal.id)
    assert replayed.id == committed.id
    assert replayed.sequence == 1
  end

  defp insert_goal do
    %Goal{}
    |> Goal.changeset(%{"title" => "A goal"})
    |> Ecto.Changeset.put_change(:owner_id, Ecto.UUID.generate())
    |> Repo.insert!()
  end

  defp insert_task(goal) do
    %TrajectoryTask{}
    |> TrajectoryTask.changeset(%{"title" => "A task"})
    |> Ecto.Changeset.put_change(:goal_id, goal.id)
    |> Repo.insert!()
  end

  defp insert_run(goal, task) do
    %RunRecord{
      id: Ecto.UUID.generate(),
      goal_id: goal.id,
      task_id: task.id,
      dispatch_id: Ecto.UUID.generate(),
      provider_id: "test",
      workspace_ref: "workspace",
      request_version: 1,
      prompt: "test",
      policy: %{},
      requested_capabilities: %{},
      status: "requested",
      projection_sequence: 0
    }
    |> Repo.insert!()
  end

  defp stop_writer(goal_id) do
    assert [{pid, _value}] = Registry.lookup(Shoestring.Trajectory.WriterRegistry, goal_id)
    ref = Process.monitor(pid)
    assert :ok = DynamicSupervisor.terminate_child(Shoestring.Trajectory.WriterSupervisor, pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}
    assert reason in [:normal, :shutdown]
  end

  defp valid_input(idempotency_key \\ nil) do
    base = %{
      "type" => "decision.recorded",
      "schema_version" => 1,
      "actor" => "system",
      "payload" => %{"decision" => "continue"}
    }

    if idempotency_key do
      Map.put(base, "idempotency_key", idempotency_key)
    else
      base
    end
  end
end
