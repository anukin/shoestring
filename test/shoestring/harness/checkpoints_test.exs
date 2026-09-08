defmodule Shoestring.Harness.CheckpointsTest do
  @moduledoc """
  Hermetic DataCase tests for the durable checkpoint writer: ownership
  checks, artifact pre-checks mirroring the projector, canonical
  `EventPayload.checkpoint/1` mapping, and `checkpoint-created:<id>`
  idempotency with `{:ok, :replayed}` replays.

  Locking note (standing contract): this writer is new surface in this
  slice, so on the pre-fix commit these tests error on the missing module
  (documentation, not a behavior-change lock). Stated honestly here rather
  than claimed as coverage.
  """
  use Shoestring.DataCase, async: false

  import Ecto.Query

  alias Shoestring.Harness.{Checkpoint, CheckpointRecord, Checkpoints, Projector}
  alias Shoestring.Test.FixedClock
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Trajectory.TrajectoryEvent

  setup do
    goal = FakeHelpers.insert_goal()
    task = FakeHelpers.insert_task(goal)
    dispatch_id = Ecto.UUID.generate()
    run = FakeHelpers.insert_run_record(goal, task, dispatch_id)
    {:ok, goal: goal, task: task, run: run}
  end

  defp checkpoint_attrs(run, overrides \\ %{}) do
    Map.merge(
      %{
        version: 1,
        checkpoint_id: Ecto.UUID.generate(),
        goal_id: run.goal_id,
        run_id: run.id,
        acceptance_contract: %{criteria: ["tests pass"]},
        repository_state: %{revision: "abc123", dirty: false},
        evidence: ["suite green"],
        decisions: ["approach A"],
        unresolved_issues: [],
        next_action: "continue from step 3",
        stop_reason: "deferred",
        artifact_ids: [],
        extensions: %{}
      },
      overrides
    )
  end

  test "records checkpoint contents and projects the checkpoint row", %{goal: goal, run: run} do
    assert {:ok, recorded} =
             Checkpoints.record(goal.id, checkpoint_attrs(run), now: FixedClock.now())

    assert recorded.outcome == :recorded
    assert [%{type: "checkpoint.created"}] = recorded.events
    assert hd(recorded.events).idempotency_key == "checkpoint-created:#{recorded.checkpoint_id}"
    assert %Checkpoint{} = recorded.checkpoint

    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    record = Repo.get!(CheckpointRecord, recorded.checkpoint_id)
    assert record.goal_id == goal.id
    assert record.run_id == run.id
    assert record.next_action == "continue from step 3"
    assert record.stop_reason == "deferred"
  end

  test "identical replay returns the recorded checkpoint with no new events", %{
    goal: goal,
    run: run
  } do
    attrs = checkpoint_attrs(run)
    assert {:ok, first} = Checkpoints.record(goal.id, attrs, now: FixedClock.now())

    events_before = event_count(goal.id, "checkpoint.created")

    assert {:ok, second} = Checkpoints.record(goal.id, attrs, now: FixedClock.now())

    assert second.outcome == :replayed
    assert second.events == []
    assert second.checkpoint_id == first.checkpoint_id
    assert second.checkpoint.next_action == "continue from step 3"
    assert event_count(goal.id, "checkpoint.created") == events_before
  end

  test "a run owned by another goal is rejected with nothing appended", %{run: run} do
    other_goal = FakeHelpers.insert_goal(Ecto.UUID.generate())

    assert {:error, {:run_not_owned, run_id}} =
             Checkpoints.record(other_goal.id, checkpoint_attrs(run), now: FixedClock.now())

    assert run_id == run.id
    assert event_count(other_goal.id, "checkpoint.created") == 0
    assert event_count(run.goal_id, "checkpoint.created") == 0
  end

  test "a missing run is rejected", %{goal: goal, run: run} do
    missing = Ecto.UUID.generate()
    attrs = checkpoint_attrs(run, %{run_id: missing})

    assert {:error, {:run_not_found, ^missing}} =
             Checkpoints.record(goal.id, attrs, now: FixedClock.now())

    assert event_count(goal.id, "checkpoint.created") == 0
  end

  test "an artifact owned by another goal is rejected like the projector", %{
    goal: goal,
    run: run
  } do
    foreign_artifact = insert_artifact!(FakeHelpers.insert_goal(Ecto.UUID.generate()))

    assert {:error, {:artifact_not_owned, artifact_id}} =
             Checkpoints.record(
               goal.id,
               checkpoint_attrs(run, %{artifact_ids: [foreign_artifact.id]}),
               now: FixedClock.now()
             )

    assert artifact_id == foreign_artifact.id
    assert event_count(goal.id, "checkpoint.created") == 0
  end

  test "an owned artifact passes the pre-check", %{goal: goal, task: task, run: run} do
    artifact = insert_artifact!(goal, task)

    assert {:ok, recorded} =
             Checkpoints.record(goal.id, checkpoint_attrs(run, %{artifact_ids: [artifact.id]}),
               now: FixedClock.now()
             )

    assert recorded.outcome == :recorded
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)
    assert Repo.get!(CheckpointRecord, recorded.checkpoint_id)
  end

  test "invalid attrs fail closed with nothing appended", %{goal: goal, run: run} do
    assert {:error, _changeset} =
             Checkpoints.record(goal.id, checkpoint_attrs(run, %{next_action: ""}),
               now: FixedClock.now()
             )

    assert event_count(goal.id, "checkpoint.created") == 0
  end

  defp event_count(goal_id, type) do
    Repo.aggregate(
      from(event in TrajectoryEvent, where: event.goal_id == ^goal_id and event.type == ^type),
      :count,
      :id
    )
  end

  defp insert_artifact!(goal, task \\ nil) do
    %Shoestring.Trajectory.Artifact{}
    |> Shoestring.Trajectory.Artifact.changeset(%{
      "sha256" => String.duplicate("a", 64),
      "byte_size" => 12,
      "media_type" => "text/plain",
      "location" => "artifacts/#{Ecto.UUID.generate()}.txt"
    })
    |> Ecto.Changeset.put_change(:goal_id, goal.id)
    |> Ecto.Changeset.put_change(:task_id, task && task.id)
    |> Repo.insert!()
  end
end
