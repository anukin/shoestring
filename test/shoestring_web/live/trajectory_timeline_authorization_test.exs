defmodule ShoestringWeb.TrajectoryTimelineAuthorizationTest do
  use ShoestringWeb.ConnCase, async: false

  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.Goal
  alias ShoestringWeb.TrajectoryTimelineLive

  test "nil scope is allowed for the documented local-user mode" do
    goal = %Goal{owner_id: Ecto.UUID.generate()}

    assert TrajectoryTimelineLive.authorized_goal?(goal, nil)
  end

  test "present scopes must contain a valid matching owner" do
    owner_id = Ecto.UUID.generate()
    goal = %Goal{owner_id: owner_id}

    refute TrajectoryTimelineLive.authorized_goal?(goal, %{})
    refute TrajectoryTimelineLive.authorized_goal?(goal, %{user: %{}})
    refute TrajectoryTimelineLive.authorized_goal?(goal, %{user_id: "not-a-uuid"})
    refute TrajectoryTimelineLive.authorized_goal?(goal, %{user_id: Ecto.UUID.generate()})
    refute TrajectoryTimelineLive.authorized_goal?(goal, :malformed)

    assert TrajectoryTimelineLive.authorized_goal?(goal, %{user_id: owner_id})
    assert TrajectoryTimelineLive.authorized_goal?(goal, %{user: %{id: owner_id}})
  end

  test "denied present scopes do not retain the goal or its events" do
    goal = insert_goal()
    event = append_event(goal.id)

    for scope <- [%{}, %{user: %{}}, %{user_id: "not-a-uuid"}, %{user_id: Ecto.UUID.generate()}] do
      assert {:ok, socket} =
               TrajectoryTimelineLive.mount(
                 %{"goal_id" => goal.id},
                 %{},
                 socket_with_scope(scope)
               )

      assert socket.assigns.goal == nil
      assert socket.assigns.timeline_error == "Goal unavailable."
      assert socket.assigns.streams.events.inserts == []

      refute socket.assigns.streams.events.inserts
             |> Enum.any?(fn {_id, _at, item, _, _} -> item.id == event.id end)
    end
  end

  test "a matching present scope can mount the goal timeline" do
    goal = insert_goal()

    assert {:ok, socket} =
             TrajectoryTimelineLive.mount(
               %{"goal_id" => goal.id},
               %{},
               socket_with_scope(%{user_id: goal.owner_id})
             )

    assert socket.assigns.goal.id == goal.id
    assert socket.assigns.timeline_error == nil
  end

  defp socket_with_scope(scope) do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, current_scope: scope},
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}}
    }
  end

  defp insert_goal do
    %Goal{}
    |> Goal.changeset(%{"title" => "Private timeline"})
    |> Ecto.Changeset.put_change(:owner_id, Ecto.UUID.generate())
    |> Repo.insert!()
  end

  defp append_event(goal_id) do
    assert {:ok, event} =
             Trajectory.append(goal_id, %{
               "type" => "decision.recorded",
               "schema_version" => 1,
               "actor" => "authorization-test",
               "payload" => %{"decision" => "private"},
               "idempotency_key" => "authorization-#{goal_id}"
             })

    event
  end
end
