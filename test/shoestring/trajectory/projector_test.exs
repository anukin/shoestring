defmodule Shoestring.Trajectory.ProjectorTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{Goal, Projector, ProjectorPosition, Task, TrajectoryEvent}

  test "pure transitions deterministically project goal and task state" do
    goal_id = Ecto.UUID.generate()
    task_id = Ecto.UUID.generate()
    goal = %Goal{id: goal_id, owner_id: Ecto.UUID.generate(), title: "Initial", status: "active"}

    events = [
      event(goal_id, 1, "goal.created", %{"title" => "Projected goal"}),
      event(goal_id, 2, "task.created", %{"task_id" => task_id, "title" => "Projected task"}),
      event(goal_id, 3, "decision.recorded", %{"decision" => "continue"}),
      event(goal_id, 4, "task.completed", %{"task_id" => task_id})
    ]

    assert {:ok, %{goal: projected_goal, tasks: tasks}} = Projector.replay_events(goal, events)
    assert projected_goal.title == "Projected goal"
    assert tasks[task_id].status == "completed"
  end

  test "project applies in sequence, persists progress, and resumes after interruption" do
    goal = insert_goal()
    task_id = Ecto.UUID.generate()

    append_events(goal.id, task_id)

    assert {:ok, position} = Projector.project(goal.id, max_events: 2)
    assert position.last_sequence == 2
    assert position.status == "ok"

    assert {:ok, resumed} = Projector.project(goal.id)
    assert resumed.last_sequence == 4
    assert Repo.get(ProjectorPosition, resumed.id).last_sequence == 4
    assert Repo.get(Goal, goal.id).title == "Projected goal"
    assert Repo.get(Task, task_id).status == "completed"
  end

  test "rebuild resets derived state and reproduces the same projection" do
    goal = insert_goal()
    task_id = Ecto.UUID.generate()
    append_events(goal.id, task_id)

    assert {:ok, before_position} = Projector.project(goal.id)
    before_goal = Repo.get!(Goal, goal.id)
    before_task = Repo.get!(Task, task_id)

    event_ids =
      Repo.all(from event in TrajectoryEvent, where: event.goal_id == ^goal.id, select: event.id)

    assert {:ok, rebuilt_position} = Projector.rebuild(goal.id)
    assert rebuilt_position.last_sequence == before_position.last_sequence
    assert projection_fields(Repo.get!(Goal, goal.id)) == projection_fields(before_goal)
    assert projection_fields(Repo.get!(Task, task_id)) == projection_fields(before_task)

    assert Repo.all(
             from event in TrajectoryEvent, where: event.goal_id == ^goal.id, select: event.id
           ) == event_ids
  end

  test "unsupported history halts visibly at the last good sequence" do
    goal = insert_goal()
    append_events(goal.id, Ecto.UUID.generate())

    %TrajectoryEvent{goal_id: goal.id, sequence: 5}
    |> TrajectoryEvent.changeset(%{
      "type" => "future.event",
      "schema_version" => 1,
      "actor" => "fixture",
      "occurred_at" => ~U[2026-08-29 12:00:00Z],
      "payload" => %{}
    })
    |> Repo.insert!()

    assert {:error, {:projection_failed, 5, {:unknown_event_type, "future.event"}}} =
             Projector.project(goal.id)

    position = Repo.get_by!(ProjectorPosition, goal_id: goal.id, projector: "goal_task")
    assert position.last_sequence == 4
    assert position.status == "failed"
    assert position.error_detail =~ "future.event"

    assert {:error, {:projection_failed, 5, {:unknown_event_type, "future.event"}}} =
             Projector.project(goal.id)
  end

  test "invalid transitions halt visibly without advancing the position" do
    goal = insert_goal()
    task_id = Ecto.UUID.generate()

    assert {:ok, _event} =
             Trajectory.append(goal.id, %{
               "type" => "task.completed",
               "schema_version" => 1,
               "actor" => "system",
               "payload" => %{"task_id" => task_id},
               "idempotency_key" => "missing-task"
             })

    assert {:error, {:projection_failed, 1, {:invalid_transition, :task_not_found, ^task_id}}} =
             Projector.project(goal.id)

    position = Repo.get_by!(ProjectorPosition, goal_id: goal.id, projector: "goal_task")
    assert position.last_sequence == 0
    assert position.status == "failed"
  end

  test "an unsupported event version halts visibly" do
    goal = insert_goal()

    %TrajectoryEvent{goal_id: goal.id, sequence: 1}
    |> TrajectoryEvent.changeset(%{
      "type" => "decision.recorded",
      "schema_version" => 99,
      "actor" => "fixture",
      "occurred_at" => ~U[2026-08-29 12:00:00Z],
      "payload" => %{"decision" => "future"}
    })
    |> Repo.insert!()

    assert {:error, {:projection_failed, 1, {:unknown_event_version, "decision.recorded", 99}}} =
             Projector.project(goal.id)
  end

  test "a failed goal projection does not block another goal" do
    failed_goal = insert_goal()
    healthy_goal = insert_goal()
    append_events(healthy_goal.id, Ecto.UUID.generate())

    %TrajectoryEvent{goal_id: failed_goal.id, sequence: 1}
    |> TrajectoryEvent.changeset(%{
      "type" => "future.event",
      "schema_version" => 1,
      "actor" => "fixture",
      "occurred_at" => ~U[2026-08-29 12:00:00Z],
      "payload" => %{}
    })
    |> Repo.insert!()

    assert {:error, {:projection_failed, 1, {:unknown_event_type, "future.event"}}} =
             Projector.project(failed_goal.id)

    assert {:ok, healthy_position} = Projector.project(healthy_goal.id)
    assert healthy_position.last_sequence == 4
  end

  test "projection changes publish only after the progress transaction commits" do
    goal = insert_goal()
    append_events(goal.id, Ecto.UUID.generate())
    test_pid = self()
    goal_id = goal.id

    publish_fun = fn _pubsub, _topic, {:trajectory_projection_updated, ^goal_id, sequence} ->
      position = Repo.get_by!(ProjectorPosition, goal_id: goal_id, projector: "goal_task")
      send(test_pid, {:published, sequence, position.last_sequence})
      :ok
    end

    assert {:ok, position} = Projector.project(goal.id, publish_fun: publish_fun)
    assert position.last_sequence == 4
    assert_receive {:published, 1, 1}
    assert_receive {:published, 4, 4}
  end

  defp append_events(goal_id, task_id) do
    assert {:ok, _} =
             Trajectory.append(goal_id, %{
               "type" => "goal.created",
               "schema_version" => 1,
               "actor" => "system",
               "payload" => %{"title" => "Projected goal"},
               "idempotency_key" => "goal-#{goal_id}"
             })

    assert {:ok, _} =
             Trajectory.append(goal_id, %{
               "type" => "task.created",
               "schema_version" => 1,
               "actor" => "system",
               "payload" => %{"task_id" => task_id, "title" => "Projected task"},
               "idempotency_key" => "task-#{goal_id}"
             })

    assert {:ok, _} =
             Trajectory.append(goal_id, %{
               "type" => "decision.recorded",
               "schema_version" => 1,
               "actor" => "system",
               "payload" => %{"decision" => "continue"},
               "idempotency_key" => "decision-#{goal_id}"
             })

    assert {:ok, _} =
             Trajectory.append(goal_id, %{
               "type" => "task.completed",
               "schema_version" => 1,
               "actor" => "system",
               "payload" => %{"task_id" => task_id},
               "idempotency_key" => "completed-#{goal_id}"
             })
  end

  defp insert_goal do
    %Goal{}
    |> Goal.changeset(%{"title" => "Initial goal"})
    |> Ecto.Changeset.put_change(:owner_id, Ecto.UUID.generate())
    |> Repo.insert!()
  end

  defp projection_fields(struct) do
    struct
    |> Map.from_struct()
    |> Map.take([:id, :owner_id, :title, :description, :status, :position, :goal_id])
  end

  defp event(goal_id, sequence, type, payload) do
    %TrajectoryEvent{
      id: Ecto.UUID.generate(),
      goal_id: goal_id,
      sequence: sequence,
      type: type,
      actor: "system",
      occurred_at: ~U[2026-08-29 12:00:00Z],
      schema_version: 1,
      payload: payload
    }
  end
end
