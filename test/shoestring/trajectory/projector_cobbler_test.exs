defmodule Shoestring.Trajectory.ProjectorCobblerTest do
  @moduledoc """
  Hermetic regression test: the goal/task projector survives `cobbler.*`
  events (registered command/claim outcomes as well as unknown future
  `cobbler.*` types) and `admission.decided` events instead of halting at
  the last good sequence. Goal/task rows still project normally around
  them. Non-cobbler unknown events still halt visibly (covered by
  `Shoestring.Trajectory.ProjectorTest`).
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{Goal, Projector, ProjectorPosition, TrajectoryEvent}

  import Shoestring.Test.CobblerHelpers

  test "projector advances past admission and cobbler events, including unknown future ones" do
    goal = create_goal!()
    task_id = Ecto.UUID.generate()

    assert {:ok, _} =
             Trajectory.append(goal.id, %{
               "type" => "goal.created",
               "schema_version" => 1,
               "actor" => "system",
               "payload" => %{"title" => "Cobbler-projected goal"},
               "idempotency_key" => "goal-#{goal.id}"
             })

    admission = append_admission_event!(goal.id)

    assert {:ok, %{outcome: :recorded}} =
             Shoestring.Cobbler.Commands.submit(
               goal.id,
               claim_command(admission, command_id: "cmd-projector-1"),
               now: now()
             )

    # Sequence so far: 1 goal.created, 2 admission.decided,
    # 3 cobbler.command.accepted, 4 cobbler.claim.acquired.
    %TrajectoryEvent{goal_id: goal.id, sequence: 5}
    |> TrajectoryEvent.changeset(%{
      "type" => "cobbler.future_probe",
      "schema_version" => 1,
      "actor" => "fixture",
      "occurred_at" => ~U[2026-09-07 12:00:00Z],
      "payload" => %{"note" => "a future cobbler event this projector never learned"}
    })
    |> Repo.insert!()

    assert {:ok, position} = Projector.project(goal.id)
    assert position.last_sequence == 5
    assert position.status == "ok"

    # Goal/task projection still applied around the ignored events.
    assert Repo.get!(Goal, goal.id).title == "Cobbler-projected goal"

    assert {:ok, _event} =
             Trajectory.append(goal.id, %{
               "type" => "task.created",
               "schema_version" => 1,
               "actor" => "system",
               "payload" => %{"task_id" => task_id, "title" => "After cobbler"},
               "idempotency_key" => "task-after-#{goal.id}"
             })

    assert {:ok, resumed} = Projector.project(goal.id)
    assert resumed.last_sequence == 6
    assert resumed.status == "ok"
    assert Repo.get!(Shoestring.Trajectory.Task, task_id).title == "After cobbler"

    # Failed-state honesty is preserved for real gaps: nothing is marked failed.
    assert Repo.get_by!(ProjectorPosition, goal_id: goal.id, projector: "goal_task").status ==
             "ok"
  end
end
