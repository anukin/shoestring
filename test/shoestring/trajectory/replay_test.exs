defmodule Shoestring.Trajectory.ReplayTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{Goal, TrajectoryEvent}

  test "replay and stream are ordered by sequence" do
    goal = insert_goal()

    assert {:ok, first} = Trajectory.append(goal.id, input("first"))
    assert {:ok, second} = Trajectory.append(goal.id, input("second"))
    assert {:ok, [replayed_first, replayed_second]} = Trajectory.replay(goal.id)
    assert [replayed_first.id, replayed_second.id] == [first.id, second.id]
    assert [replayed_first.sequence, replayed_second.sequence] == [1, 2]

    assert {:ok, stream} = Trajectory.stream(goal.id)
    assert Enum.map(stream, & &1.sequence) == [1, 2]
  end

  test "replay and stream visibly reject unsupported stored history" do
    goal = insert_goal()

    %TrajectoryEvent{goal_id: goal.id, sequence: 1}
    |> TrajectoryEvent.changeset(%{
      "type" => "future.event",
      "schema_version" => 1,
      "actor" => "fixture",
      "occurred_at" => ~U[2026-08-29 12:00:00Z],
      "payload" => %{}
    })
    |> Repo.insert!()

    assert {:error, {:unknown_event_type, "future.event"}} = Trajectory.replay(goal.id)
    assert {:error, {:unknown_event_type, "future.event"}} = Trajectory.stream(goal.id)
  end

  test "a writer restart reconstructs the next sequence from sqlite" do
    goal = insert_goal()
    assert {:ok, first} = Trajectory.append(goal.id, input("before-restart"))
    assert [{pid, _value}] = Registry.lookup(Shoestring.Trajectory.WriterRegistry, goal.id)

    ref = Process.monitor(pid)
    assert :ok = DynamicSupervisor.terminate_child(Shoestring.Trajectory.WriterSupervisor, pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}
    assert reason in [:normal, :shutdown]

    assert {:ok, second} = Trajectory.append(goal.id, input("after-restart"))
    assert first.sequence == 1
    assert second.sequence == 2
  end

  defp insert_goal do
    %Goal{}
    |> Goal.changeset(%{"title" => "A goal"})
    |> Ecto.Changeset.put_change(:owner_id, Ecto.UUID.generate())
    |> Repo.insert!()
  end

  defp input(key) do
    %{
      "type" => "decision.recorded",
      "schema_version" => 1,
      "actor" => "system",
      "idempotency_key" => key,
      "payload" => %{"decision" => key}
    }
  end
end
