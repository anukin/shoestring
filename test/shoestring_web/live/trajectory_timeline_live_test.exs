defmodule ShoestringWeb.TrajectoryTimelineLiveTest do
  use ShoestringWeb.ConnCase, async: false

  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{Goal, Projector, TrajectoryEvent}

  test "renders one ordered canonical timeline with projection state", %{conn: conn} do
    goal = insert_goal()
    events = append_fixture_events(goal.id)
    assert {:ok, position} = Projector.project(goal.id)
    assert position.status == "ok"

    {:ok, view, _html} = live(conn, "/goals/#{goal.id}/timeline")

    assert has_element?(view, "#goal-timeline")
    assert has_element?(view, "#goal-identity[data-goal-id='#{goal.id}']")
    assert has_element?(view, "#projection-status[data-status='ok']")

    for {event, sequence} <- Enum.zip(events, 1..4) do
      assert has_element?(view, "#timeline-event-#{event.id}[data-sequence='#{sequence}']")
      assert has_element?(view, "#event-type-#{event.id}")
      assert has_element?(view, "#event-actor-#{event.id}")
      assert has_element?(view, "#event-time-#{event.id}")
    end
  end

  test "refreshes from replay after committed event and projection notifications", %{conn: conn} do
    goal = insert_goal()
    first = append_event(goal.id, "first")

    {:ok, view, _html} = live(conn, "/goals/#{goal.id}/timeline")
    assert has_element?(view, "#timeline-event-#{first.id}[data-sequence='1']")
    assert has_element?(view, "#projection-status[data-status='not_projected']")

    second = append_event(goal.id, "second")
    assert has_element?(view, "#timeline-event-#{second.id}[data-sequence='2']")

    assert {:ok, position} = Projector.project(goal.id)
    assert position.last_sequence == 2
    assert has_element?(view, "#projection-status[data-status='ok']")
  end

  test "a failed publication is recovered by canonical replay on mount", %{conn: conn} do
    goal = insert_goal()
    publish_failure = fn _pubsub, _topic, _message -> {:error, :pubsub_unavailable} end

    assert {:error, {:publish_failed, :pubsub_unavailable, committed}} =
             Trajectory.append(goal.id, valid_input("committed-before-failure"),
               writer_opts: [publish_fun: publish_failure]
             )

    {:ok, view, _html} = live(conn, "/goals/#{goal.id}/timeline")

    assert has_element?(view, "#timeline-event-#{committed.id}[data-sequence='1']")
  end

  test "writer restart and remount restore the ordered history", %{conn: conn} do
    goal = insert_goal()
    first = append_event(goal.id, "before-restart")
    stop_writer(goal.id)

    second = append_event(goal.id, "after-restart")
    {:ok, view, _html} = live(conn, "/goals/#{goal.id}/timeline")

    assert has_element?(view, "#timeline-event-#{first.id}[data-sequence='1']")
    assert has_element?(view, "#timeline-event-#{second.id}[data-sequence='2']")
  end

  test "gaps and incompatible projection state are visible and safe", %{conn: conn} do
    goal = insert_goal()

    insert_event!(goal.id, 2, "decision.recorded", %{"decision" => "gap"})
    {:ok, gap_view, _html} = live(conn, "/goals/#{goal.id}/timeline")
    assert has_element?(gap_view, "#timeline-error")
    refute has_element?(gap_view, "#timeline-event")

    incompatible_goal = insert_goal()
    insert_event!(incompatible_goal.id, 1, "future.event", %{})

    assert {:error, {:projection_failed, 1, {:unknown_event_type, "future.event"}}} =
             Projector.project(incompatible_goal.id)

    {:ok, incompatible_view, _html} =
      live(conn, "/goals/#{incompatible_goal.id}/timeline")

    assert has_element?(incompatible_view, "#projection-status[data-status='failed']")
    assert has_element?(incompatible_view, "#projection-error")
  end

  test "missing goals fail safely", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/goals/#{Ecto.UUID.generate()}/timeline")

    assert has_element?(view, "#timeline-error")
    refute has_element?(view, "#goal-identity")
  end

  test "local mode renders a redacted timeline payload", %{conn: conn} do
    goal = insert_goal()

    event =
      append(
        goal.id,
        "decision.recorded",
        %{"decision" => "Bearer abc/def+=-?public=1"},
        "redacted"
      )

    {:ok, view, _html} = live(conn, "/goals/#{goal.id}/timeline")

    assert has_element?(view, "#event-payload-#{event.id}", "[REDACTED]")
    refute has_element?(view, "#event-payload-#{event.id}", "Bearer abc/def+=-")
  end

  defp append_fixture_events(goal_id) do
    task_id = Ecto.UUID.generate()

    [
      append(goal_id, "goal.created", %{"title" => "Timeline goal"}, "goal"),
      append(
        goal_id,
        "task.created",
        %{"task_id" => task_id, "title" => "Timeline task"},
        "task"
      ),
      append(goal_id, "decision.recorded", %{"decision" => "continue"}, "decision"),
      append(goal_id, "task.completed", %{"task_id" => task_id}, "completed")
    ]
  end

  defp append_event(goal_id, key),
    do: append(goal_id, "decision.recorded", %{"decision" => key, "rationale" => "safe"}, key)

  defp append(goal_id, type, payload, key) do
    assert {:ok, event} =
             Trajectory.append(goal_id, %{
               "type" => type,
               "schema_version" => 1,
               "actor" => "timeline-test",
               "payload" => payload,
               "idempotency_key" => "timeline-#{key}-#{goal_id}"
             })

    event
  end

  defp insert_event!(goal_id, sequence, type, payload) do
    %TrajectoryEvent{
      id: Ecto.UUID.generate(),
      goal_id: goal_id,
      sequence: sequence,
      type: type,
      actor: "fixture",
      occurred_at: ~U[2026-08-29 12:00:00.000000Z],
      schema_version: 1,
      payload: payload
    }
    |> TrajectoryEvent.changeset(%{})
    |> Repo.insert!()
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
    |> Goal.changeset(%{"title" => "Timeline goal"})
    |> Ecto.Changeset.put_change(:owner_id, Ecto.UUID.generate())
    |> Repo.insert!()
  end

  defp valid_input(key) do
    %{
      "type" => "decision.recorded",
      "schema_version" => 1,
      "actor" => "timeline-test",
      "payload" => %{"decision" => key},
      "idempotency_key" => key
    }
  end
end
