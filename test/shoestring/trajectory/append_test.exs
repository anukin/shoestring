defmodule Shoestring.Trajectory.AppendTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{Goal, TrajectoryEvent}

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

  test "a busy writer for one goal does not block another goal" do
    first_goal = insert_goal()
    second_goal = insert_goal()

    always_busy = fn _input, _state -> {:error, :busy} end

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
