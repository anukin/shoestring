defmodule Shoestring.Trajectory.TrajectoryEventTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.Repo
  alias Shoestring.Trajectory.{Goal, Task, TrajectoryEvent}

  test "events require an envelope and preserve nullable run ids" do
    goal = insert_goal()
    task = insert_task(goal)
    occurred_at = ~U[2026-08-29 12:00:00.123456Z]

    event =
      insert_event!(goal, task, %{
        sequence: 1,
        run_id: nil,
        occurred_at: occurred_at,
        type: "task.created",
        actor: "system",
        schema_version: 1,
        payload: %{"task_id" => task.id, "title" => task.title}
      })

    assert event.id
    assert event.goal_id == goal.id
    assert event.task_id == task.id
    assert event.run_id == nil
    assert event.occurred_at == occurred_at

    run_id = Ecto.UUID.generate()
    event_with_run = insert_event!(goal, nil, %{sequence: 2, run_id: run_id})
    assert event_with_run.run_id == run_id

    invalid = TrajectoryEvent.changeset(%TrajectoryEvent{}, %{"type" => ""})
    assert "can't be blank" in errors_on(invalid).goal_id
    assert "can't be blank" in errors_on(invalid).payload

    programmatic =
      TrajectoryEvent.changeset(%TrajectoryEvent{}, %{
        "goal_id" => Ecto.UUID.generate(),
        "sequence" => 99,
        "task_id" => Ecto.UUID.generate(),
        "run_id" => Ecto.UUID.generate()
      })

    refute Map.has_key?(programmatic.changes, :goal_id)
    refute Map.has_key?(programmatic.changes, :sequence)
    refute Map.has_key?(programmatic.changes, :task_id)
    refute Map.has_key?(programmatic.changes, :run_id)
  end

  test "sequence is positive and unique per goal" do
    goal = insert_goal()

    assert {:error, changeset} =
             insert_event(goal, nil, %{sequence: 0, idempotency_key: "zero"})

    assert "must be greater than 0" in errors_on(changeset).sequence

    insert_event!(goal, nil, %{sequence: 1, idempotency_key: "first"})

    assert {:error, changeset} =
             insert_event(goal, nil, %{sequence: 1, idempotency_key: "duplicate-sequence"})

    assert "has already been taken" in errors_on(changeset).sequence
  end

  test "idempotency keys are unique within a goal but reusable across goals" do
    goal = insert_goal()
    other_goal = insert_goal()
    key = "append-request-1"

    insert_event!(goal, nil, %{sequence: 1, idempotency_key: key})

    assert {:error, changeset} =
             insert_event(goal, nil, %{sequence: 2, idempotency_key: key})

    assert "has already been taken" in errors_on(changeset).idempotency_key
    assert {:ok, _event} = insert_event(other_goal, nil, %{sequence: 1, idempotency_key: key})
    assert {:ok, _event_without_key} = insert_event(goal, nil, %{sequence: 2})
  end

  test "task and parent event references are optional but checked when supplied" do
    goal = insert_goal()
    parent = insert_event!(goal, nil, %{sequence: 1})

    event = insert_event!(goal, nil, %{sequence: 2, parent_event_id: parent.id})
    assert event.parent_event_id == parent.id

    assert_raise Ecto.ConstraintError, fn ->
      insert_event!(goal, nil, %{sequence: 3, task_id: Ecto.UUID.generate()})
    end
  end

  defp insert_goal do
    %Goal{}
    |> Goal.changeset(%{"title" => "A goal"})
    |> Ecto.Changeset.put_change(:owner_id, Ecto.UUID.generate())
    |> Repo.insert!()
  end

  defp insert_task(goal) do
    %Task{}
    |> Task.changeset(%{"title" => "A task"})
    |> Ecto.Changeset.put_change(:goal_id, goal.id)
    |> Repo.insert!()
  end

  defp insert_event!(goal, task, attrs) do
    {:ok, event} = insert_event(goal, task, attrs)
    event
  end

  defp insert_event(goal, task, attrs) do
    defaults = %{
      occurred_at: ~U[2026-08-29 12:00:00Z],
      type: "decision.recorded",
      actor: "system",
      schema_version: 1,
      payload: %{"decision" => "continue"}
    }

    programmatic_fields = [:goal_id, :task_id, :run_id, :sequence, :parent_event_id]
    programmatic_attrs = Map.take(attrs, programmatic_fields)
    envelope_attrs = Map.drop(attrs, programmatic_fields)

    %TrajectoryEvent{goal_id: goal.id, task_id: task && task.id}
    |> struct(programmatic_attrs)
    |> TrajectoryEvent.changeset(Map.merge(defaults, envelope_attrs))
    |> Repo.insert()
  end
end
