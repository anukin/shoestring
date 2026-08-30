defmodule Shoestring.Trajectory.SchemaTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.Repo
  alias Shoestring.Trajectory.{Artifact, Goal, ProjectorPosition, Task, TrajectoryEvent}

  test "foundation schemas use UUIDv4 binary ids and UTC microsecond timestamps" do
    for schema <- [Goal, Task, TrajectoryEvent, Artifact, ProjectorPosition] do
      assert schema.__schema__(:type, :id) == :binary_id
      assert schema.__schema__(:autogenerate_id) == {:id, :id, :binary_id}
    end

    for schema <- [Goal, Task, Artifact, ProjectorPosition] do
      assert schema.__schema__(:type, :inserted_at) == :utc_datetime_usec
      assert schema.__schema__(:type, :updated_at) == :utc_datetime_usec
    end

    assert TrajectoryEvent.__schema__(:type, :occurred_at) == :utc_datetime_usec
  end

  test "goal and task creation changesets keep ownership and foreign keys programmatic" do
    owner_id = Ecto.UUID.generate()
    goal_id = Ecto.UUID.generate()

    goal_changeset =
      Goal.changeset(%Goal{}, %{
        "id" => Ecto.UUID.generate(),
        "owner_id" => Ecto.UUID.generate(),
        "title" => "Ship the trajectory spine"
      })

    refute Map.has_key?(goal_changeset.changes, :id)
    refute Map.has_key?(goal_changeset.changes, :owner_id)

    goal =
      %Goal{}
      |> Goal.changeset(%{"title" => "Ship the trajectory spine"})
      |> Ecto.Changeset.put_change(:owner_id, owner_id)
      |> Repo.insert!()

    task_changeset =
      Task.changeset(%Task{}, %{
        "goal_id" => goal_id,
        "title" => "Define the event envelope"
      })

    refute Map.has_key?(task_changeset.changes, :goal_id)

    task =
      %Task{}
      |> Task.changeset(%{"title" => "Define the event envelope"})
      |> Ecto.Changeset.put_change(:goal_id, goal.id)
      |> Repo.insert!()

    assert task.goal_id == goal.id
    assert uuid_version(goal.id) == 4
  end

  test "foreign keys enforce goal ownership boundaries" do
    assert_raise Ecto.ConstraintError, fn ->
      %Task{}
      |> Task.changeset(%{"title" => "orphan"})
      |> Ecto.Changeset.put_change(:goal_id, Ecto.UUID.generate())
      |> Repo.insert!()
    end
  end

  test "artifacts store portable metadata and reject unsafe locations" do
    attrs = %{
      "goal_id" => Ecto.UUID.generate(),
      "task_id" => Ecto.UUID.generate(),
      "sha256" => String.duplicate("a", 64),
      "byte_size" => 10,
      "media_type" => "text/plain",
      "location" => "/absolute/path.txt"
    }

    changeset = Artifact.changeset(%Artifact{}, attrs)

    assert "must be a safe relative path" in errors_on(changeset).location
    refute Map.has_key?(changeset.changes, :goal_id)
    refute Map.has_key?(changeset.changes, :task_id)
  end

  test "database check constraints are mapped by every foundation changeset" do
    assert has_constraint?(Task.changeset(%Task{}, %{}), "tasks_position_nonnegative")

    assert has_constraint?(
             Artifact.changeset(%Artifact{}, %{}),
             "artifacts_byte_size_nonnegative"
           )

    assert has_constraint?(
             ProjectorPosition.changeset(%ProjectorPosition{}, %{}),
             "projector_positions_version_positive"
           )

    assert has_constraint?(
             ProjectorPosition.changeset(%ProjectorPosition{}, %{}),
             "projector_positions_sequence_nonnegative"
           )
  end

  defp has_constraint?(changeset, name) do
    Enum.any?(changeset.constraints, &(&1.constraint == name))
  end

  defp uuid_version(uuid) do
    uuid |> String.at(14) |> String.to_integer(16)
  end
end
