defmodule Shoestring.Trajectory.JSONLTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{ArtifactStore, Goal, JSONL, Projector, TrajectoryEvent}

  test "export is ordered, versioned, redacted, and replay fixtures do not insert events" do
    goal = insert_goal()
    root = temporary_root()
    append_fixture_events(goal.id)

    assert {:ok, artifact} =
             ArtifactStore.put(goal.id, "fixture", %{"media_type" => "text/plain"}, root: root)

    assert {:ok, event} =
             Trajectory.append(goal.id, %{
               "type" => "decision.recorded",
               "schema_version" => 1,
               "actor" => "system",
               "payload" => %{
                 "decision" => "export",
                 "rationale" => "sk-secret-value",
                 "artifact_id" => artifact.id
               },
               "idempotency_key" => "export-event"
             })

    {:ok, _} = Projector.project(goal.id)
    event_count = Repo.aggregate(TrajectoryEvent, :count, :id)

    assert {:ok, jsonl} = JSONL.export(goal.id, root: root)
    [manifest_line | lines_after_manifest] = String.split(jsonl, "\n", trim: true)
    event_lines = Enum.take(lines_after_manifest, 5)
    assert Jason.decode!(manifest_line)["manifest_version"] == 1

    assert Enum.map(event_lines, &Jason.decode!/1) |> Enum.map(& &1["event"]["sequence"]) == [
             1,
             2,
             3,
             4,
             5
           ]

    refute jsonl =~ "sk-secret-value"
    refute jsonl =~ "authorization"

    assert {:ok, fixture} = JSONL.decode(jsonl)
    assert {:ok, projection} = JSONL.replay_fixture(fixture, goal: Repo.get!(Goal, goal.id))
    assert projection.goal.title == "Projected goal"
    assert Repo.aggregate(TrajectoryEvent, :count, :id) == event_count
    assert event.id
  end

  test "decode rejects malformed lines, unsupported versions, and order gaps" do
    goal = insert_goal()
    append_fixture_events(goal.id)
    assert {:ok, jsonl} = JSONL.export(goal.id)
    lines = String.split(jsonl, "\n", trim: true)

    assert {:error, {:malformed_line, 2, _}} =
             JSONL.decode(Enum.join([hd(lines), "not-json"], "\n"))

    manifest = Jason.decode!(hd(lines)) |> Map.put("manifest_version", 99)

    assert {:error, {:unknown_manifest_version, 99}} =
             JSONL.decode(Enum.join([Jason.encode!(manifest) | tl(lines)], "\n"))

    [manifest_line, first_event | rest] = lines
    first = Jason.decode!(first_event)
    gap = put_in(first, ["event", "sequence"], 2)

    assert {:error, {:event_order, 2, 1}} =
             JSONL.decode(Enum.join([manifest_line, Jason.encode!(gap) | rest], "\n"))
  end

  test "export and decode detect artifact integrity failures" do
    goal = insert_goal()
    root = temporary_root()
    append_fixture_events(goal.id)

    {:ok, artifact} =
      ArtifactStore.put(goal.id, "fixture", %{"media_type" => "text/plain"}, root: root)

    File.write!(Path.join(root, artifact.location), "tampered")

    assert {:error, {:artifact_corrupt, :hash}} = JSONL.export(goal.id, root: root)

    assert {:error, {:artifact_corrupt, :hash}} =
             JSONL.export(goal.id, root: root, include_artifacts: true)
  end

  test "export drops secrets from legacy payload fields without mutating history" do
    goal = insert_goal()
    append_fixture_events(goal.id)

    legacy_payload = %{
      "decision" => "legacy",
      "api_key" => "fake-api-key",
      "metadata" => %{"password" => "fake-password"}
    }

    event = %TrajectoryEvent{
      id: Ecto.UUID.generate(),
      goal_id: goal.id,
      sequence: 5,
      type: "decision.recorded",
      actor: "legacy",
      occurred_at: ~U[2026-08-29 12:00:00.000000Z],
      schema_version: 1,
      payload: legacy_payload
    }

    Repo.insert!(TrajectoryEvent.changeset(event, %{}))

    assert {:ok, jsonl} = JSONL.export(goal.id)
    refute jsonl =~ "fake-api-key"
    refute jsonl =~ "fake-password"
    assert Repo.get!(TrajectoryEvent, event.id).payload == legacy_payload
  end

  test "artifact bytes are attached after metadata redaction without mutation" do
    goal = insert_goal()
    root = temporary_root()
    bytes = "secret: bytes that must remain exact"

    assert {:ok, artifact} =
             ArtifactStore.put(goal.id, bytes, %{"media_type" => "text/plain"}, root: root)

    assert {:ok, jsonl} = JSONL.export(goal.id, root: root, include_artifacts: true)
    assert {:ok, fixture} = JSONL.decode(jsonl)
    [exported_artifact] = fixture.artifacts
    assert Base.decode64!(exported_artifact["bytes_base64"]) == bytes
    assert exported_artifact["sha256"] == artifact.sha256
  end

  test "decode rejects unknown event types and event schema versions" do
    goal = insert_goal()
    append_fixture_events(goal.id)
    {:ok, jsonl} = JSONL.export(goal.id)
    [manifest_line, first_event | rest] = String.split(jsonl, "\n", trim: true)
    first = Jason.decode!(first_event)

    unknown_type = put_in(first, ["event", "type"], "future.event")

    assert {:error, {:unknown_event_type, "future.event"}} =
             JSONL.decode(Enum.join([manifest_line, Jason.encode!(unknown_type) | rest], "\n"))

    unknown_version = put_in(first, ["event", "schema_version"], 99)

    assert {:error, {:unknown_event_version, "goal.created", 99}} =
             JSONL.decode(Enum.join([manifest_line, Jason.encode!(unknown_version) | rest], "\n"))
  end

  defp append_fixture_events(goal_id) do
    task_id = Ecto.UUID.generate()

    inputs = [
      {"goal.created", %{"title" => "Projected goal"}, "goal"},
      {"task.created", %{"task_id" => task_id, "title" => "Projected task"}, "task"},
      {"decision.recorded", %{"decision" => "continue"}, "decision"},
      {"task.completed", %{"task_id" => task_id}, "completed"}
    ]

    for {type, payload, key} <- inputs do
      assert {:ok, _event} =
               Trajectory.append(goal_id, %{
                 "type" => type,
                 "schema_version" => 1,
                 "actor" => "system",
                 "payload" => payload,
                 "idempotency_key" => "fixture-#{key}"
               })
    end
  end

  defp temporary_root do
    root = Path.join(System.tmp_dir!(), "shoestring-jsonl-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp insert_goal do
    %Goal{}
    |> Goal.changeset(%{"title" => "JSONL goal"})
    |> Ecto.Changeset.put_change(:owner_id, Ecto.UUID.generate())
    |> Repo.insert!()
  end
end
