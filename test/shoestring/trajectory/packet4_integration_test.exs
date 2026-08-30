defmodule Shoestring.Trajectory.Packet4IntegrationTest do
  use ShoestringWeb.ConnCase, async: false

  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{Goal, JSONL, Projector, Task}

  test "public fixture flow projects, survives restart, rebuilds, and round-trips JSONL", %{
    conn: conn
  } do
    goal = insert_goal()
    task_id = Ecto.UUID.generate()

    append(goal.id, "goal.created", %{"title" => "Demo goal"}, "goal")
    append(goal.id, "task.created", %{"task_id" => task_id, "title" => "Demo task"}, "task")

    append(
      goal.id,
      "decision.recorded",
      %{"decision" => "continue", "rationale" => "api_key=fake-demo-secret"},
      "decision"
    )

    append(goal.id, "task.completed", %{"task_id" => task_id}, "completed")

    assert {:ok, position} = Projector.project(goal.id)
    assert position.last_sequence == 4

    {:ok, view, _html} = live(conn, "/goals/#{goal.id}/timeline")
    assert has_element?(view, "#timeline-events [data-sequence='4']")
    refute has_element?(view, "#timeline-events", "fake-demo-secret")

    stop_writer(goal.id)
    restarted = append(goal.id, "decision.recorded", %{"decision" => "restarted"}, "restart")
    assert restarted.sequence == 5

    assert {:ok, resumed} = Projector.project(goal.id)
    assert resumed.last_sequence == 5
    projected_goal_after_restart = Repo.get!(Goal, goal.id)
    projected_task_after_restart = Repo.get!(Task, task_id)

    assert {:ok, jsonl} = JSONL.export(goal.id)
    refute jsonl =~ "fake-demo-secret"
    assert {:ok, fixture} = JSONL.decode(jsonl)
    assert {:ok, replayed} = JSONL.replay_fixture(fixture, goal: projected_goal_after_restart)
    assert replayed.tasks[task_id].status == "completed"

    assert {:ok, rebuilt} = Projector.rebuild(goal.id)
    assert rebuilt.last_sequence == 5

    assert projection_fields(Repo.get!(Goal, goal.id)) ==
             projection_fields(projected_goal_after_restart)

    assert projection_fields(Repo.get!(Task, task_id)) ==
             projection_fields(projected_task_after_restart)

    {:ok, remounted, _html} =
      live(Phoenix.ConnTest.build_conn(), "/goals/#{goal.id}/timeline")

    assert has_element?(remounted, "#timeline-events [data-sequence='5']")
  end

  defp append(goal_id, type, payload, key) do
    assert {:ok, event} =
             Trajectory.append(goal_id, %{
               "type" => type,
               "schema_version" => 1,
               "actor" => "packet4-demo",
               "payload" => payload,
               "idempotency_key" => "packet4-#{key}-#{goal_id}"
             })

    event
  end

  defp stop_writer(goal_id) do
    assert [{pid, _value}] = Registry.lookup(Shoestring.Trajectory.WriterRegistry, goal_id)
    ref = Process.monitor(pid)
    assert :ok = DynamicSupervisor.terminate_child(Shoestring.Trajectory.WriterSupervisor, pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}
    assert reason in [:normal, :shutdown]
  end

  defp insert_goal do
    %Goal{}
    |> Goal.changeset(%{"title" => "Packet 4 goal"})
    |> Ecto.Changeset.put_change(:owner_id, Ecto.UUID.generate())
    |> Repo.insert!()
  end

  defp projection_fields(struct) do
    struct
    |> Map.from_struct()
    |> Map.take([:id, :owner_id, :title, :description, :status, :position, :goal_id])
  end
end
