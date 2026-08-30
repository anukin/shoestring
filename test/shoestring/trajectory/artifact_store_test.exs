defmodule Shoestring.Trajectory.ArtifactStoreTest do
  use Shoestring.DataCase, async: false

  import Ecto.Query

  alias Shoestring.Repo
  alias Shoestring.Trajectory.{Artifact, ArtifactStore, Goal, Task}

  test "put writes content-addressed bytes atomically and reads verified metadata" do
    goal = insert_goal()
    root = temporary_root()
    bytes = "artifact bytes"

    assert {:ok, artifact} =
             ArtifactStore.put(
               goal.id,
               bytes,
               %{"media_type" => "text/plain", "redacted" => true},
               root: root
             )

    assert artifact.goal_id == goal.id
    assert artifact.byte_size == byte_size(bytes)
    assert artifact.sha256 == sha256(bytes)
    assert artifact.location == Path.join(goal.id, artifact.sha256)

    assert {:ok, %{artifact: ^artifact, bytes: ^bytes}} =
             ArtifactStore.read(artifact.id, root: root)
  end

  test "trusted task ownership is persisted and cross-goal ownership is rejected" do
    goal = insert_goal()
    other_goal = insert_goal()
    task = insert_task(goal)
    other_task = insert_task(other_goal)
    root = temporary_root()

    assert {:ok, artifact} =
             ArtifactStore.put(goal.id, "owned", %{"media_type" => "text/plain"},
               root: root,
               task_id: task.id
             )

    assert artifact.task_id == task.id

    query = from artifact in Artifact, where: artifact.id == ^artifact.id
    Repo.update_all(query, set: [task_id: other_task.id])

    assert {:error, {:artifact_invalid_metadata, :task_id}} =
             ArtifactStore.read(artifact.id, root: root)

    Repo.update_all(query, set: [task_id: task.id])

    assert {:error, {:trusted_reference_not_owned, :task_id}} =
             ArtifactStore.put(goal.id, "not-owned", %{"media_type" => "text/plain"},
               root: root,
               task_id: other_task.id
             )

    refute Repo.get_by(Artifact, goal_id: goal.id, task_id: other_task.id)
  end

  test "size bounds and failures leave no temporary files" do
    goal = insert_goal()
    root = temporary_root()

    assert {:error, {:artifact_too_large, 4}} =
             ArtifactStore.put(goal.id, "abcd", %{"media_type" => "text/plain"},
               root: root,
               max_size: 3
             )

    assert {:error, {:invalid_artifact_attributes, _}} =
             ArtifactStore.put(goal.id, "bytes", %{}, root: root)

    assert Path.wildcard(Path.join(root, "**/*.tmp-*")) == []
  end

  test "missing, corrupt, conflicting, and unsafe files fail visibly" do
    goal = insert_goal()
    root = temporary_root()
    bytes = "verified"

    {:ok, artifact} =
      ArtifactStore.put(goal.id, bytes, %{"media_type" => "text/plain"}, root: root)

    path = Path.join(root, artifact.location)

    File.write!(path, "corrupt")
    assert {:error, {:artifact_corrupt, :hash}} = ArtifactStore.read(artifact.id, root: root)

    File.rm!(path)
    artifact_id = artifact.id

    assert {:error, {:artifact_missing, ^artifact_id}} =
             ArtifactStore.read(artifact.id, root: root)

    File.write!(path, "conflict")

    assert {:error, {:artifact_conflict, _}} =
             ArtifactStore.put(goal.id, bytes, %{"media_type" => "text/plain"}, root: root)

    Repo.update_all(Artifact, set: [location: "/absolute/secret"])
    assert {:error, {:artifact_unsafe_location, _}} = ArtifactStore.read(artifact.id, root: root)
  end

  defp temporary_root do
    root =
      Path.join(System.tmp_dir!(), "shoestring-artifacts-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp insert_goal do
    %Goal{}
    |> Goal.changeset(%{"title" => "Artifact goal"})
    |> Ecto.Changeset.put_change(:owner_id, Ecto.UUID.generate())
    |> Repo.insert!()
  end

  defp insert_task(goal) do
    %Task{}
    |> Task.changeset(%{"title" => "Artifact task"})
    |> Ecto.Changeset.put_change(:goal_id, goal.id)
    |> Repo.insert!()
  end

  defp sha256(bytes) do
    bytes
    |> then(fn value -> :crypto.hash(:sha256, value) end)
    |> Base.encode16(case: :lower)
  end
end
