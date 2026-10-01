defmodule Shoestring.Cobbler.PlanReplayTest do
  @moduledoc """
  Canonical durable events — not rows, not processes, not UI state — are what
  establish plan authority.

  These tests rebuild revisions, decisions, and the active authority purely
  from `cobbler.plan.*` events, including after the goal/task projector has
  been reset and replayed, and assert the rebuilt content and digest are
  reproduced rather than copied. Fully hermetic.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Cobbler.{PlanContract, PlanRevisionRecord, Plans}
  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{Projector, TrajectoryEvent}

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers, only: [create_goal!: 0]
  import Shoestring.Test.PlanFixtures

  @now ~U[2026-09-30 12:00:00.000000Z]
  @later ~U[2026-09-30 13:00:00.000000Z]

  defp opts(extra \\ []), do: Keyword.merge([now: @now, publish_fun: fn _event -> :ok end], extra)

  # A goal with: revision 1 approved, revision 2 approved (superseding 1),
  # and revision 3 rejected. Every durable outcome this slice can produce.
  defp seeded_goal do
    goal = create_goal!()

    assert {:ok, %{revision: first}} = Plans.propose(goal.id, propose_attrs(), opts())
    assert {:ok, _result} = Plans.approve(goal.id, approve_attrs(1, first.digest), opts())

    second_plan = plan(%{"goal" => goal(%{"statement" => "The second goal statement."})})

    assert {:ok, %{revision: second}} =
             Plans.propose(
               goal.id,
               propose_attrs(
                 proposal_id: "proposal-2",
                 parent_revision_number: 1,
                 plan: second_plan
               ),
               opts(now: @later)
             )

    assert {:ok, _result} =
             Plans.approve(
               goal.id,
               approve_attrs(2, second.digest, decision_id: "decision-2"),
               opts(now: @later)
             )

    third_plan = plan(%{"goal" => goal(%{"statement" => "The third goal statement."})})

    assert {:ok, %{revision: third}} =
             Plans.propose(
               goal.id,
               propose_attrs(
                 proposal_id: "proposal-3",
                 parent_revision_number: 2,
                 plan: third_plan
               ),
               opts(now: @later)
             )

    assert {:ok, _result} =
             Plans.reject(
               goal.id,
               reject_attrs(3, third.digest, decision_id: "decision-3"),
               opts(now: @later)
             )

    %{goal: goal, first: first, second: second, third: third}
  end

  describe "rebuild from canonical events" do
    test "reproduces every revision, decision, and the active authority" do
      %{goal: goal, first: first, second: second, third: third} = seeded_goal()

      assert {:ok, rebuilt} = Plans.rebuild(goal.id)
      assert rebuilt.consistent?
      assert rebuilt.divergences == []

      assert Enum.map(rebuilt.revisions, & &1["revision_number"]) == [1, 2, 3]
      assert Enum.map(rebuilt.revisions, & &1["status"]) == ["superseded", "approved", "rejected"]

      assert Enum.map(rebuilt.revisions, & &1["digest"]) == [
               first.digest,
               second.digest,
               third.digest
             ]

      assert Enum.map(rebuilt.decisions, &{&1["revision_number"], &1["kind"]}) ==
               [{1, "approve"}, {2, "approve"}, {3, "reject"}]

      assert rebuilt.authority["revision_number"] == 2
      assert rebuilt.authority["digest"] == second.digest
    end

    test "recomputes the digest from the event content rather than copying it" do
      %{goal: goal, second: second} = seeded_goal()

      assert {:ok, rebuilt} = Plans.rebuild(goal.id)
      authority = rebuilt.authority

      # The rebuilt digest is derived from the rebuilt content, and the
      # declared digest the event carried agrees with it.
      assert authority["digest"] == PlanContract.digest(authority["content"])
      assert authority["declared_digest"] == authority["digest"]
      assert authority["digest"] == second.digest
    end

    test "reproduces the stored content exactly, including deterministic ordering" do
      %{goal: goal, second: second} = seeded_goal()

      assert {:ok, rebuilt} = Plans.rebuild(goal.id)
      authority = rebuilt.authority

      assert authority["content"] == second.content
      assert authority["ordered_task_ids"] == ["survey", "widen", "narrow", "verify"]
      assert authority["authored_by"] == "human:planner"
      assert authority["author_kind"] == "human"
    end

    test "still converges after the goal/task projector is reset and replayed" do
      %{goal: goal, second: second} = seeded_goal()

      assert {:ok, _position} = Projector.rebuild(goal.id)

      assert {:ok, rebuilt} = Plans.rebuild(goal.id)
      assert rebuilt.consistent?
      assert rebuilt.authority["revision_number"] == 2
      assert rebuilt.authority["digest"] == second.digest

      # The stored rows are untouched by projector rebuild.
      assert Plans.authority(goal.id).revision_number == 2
      assert Plans.get_revision(goal.id, 1).status == "superseded"
    end

    test "the whole canonical history still validates through the trajectory boundary" do
      %{goal: goal} = seeded_goal()

      assert {:ok, events} = Trajectory.replay(goal.id)

      plan_events = Enum.filter(events, &(&1.type in Plans.event_types()))
      assert length(plan_events) == 6
    end

    test "a goal with no plan events rebuilds to an empty, authority-free state" do
      goal = create_goal!()

      assert {:ok, rebuilt} = Plans.rebuild(goal.id)
      assert rebuilt.revisions == []
      assert rebuilt.decisions == []
      assert rebuilt.authority == nil
      assert rebuilt.consistent?
    end
  end

  describe "rebuild reports divergence instead of hiding it" do
    test "names a stored revision whose status no longer matches its events" do
      %{goal: goal} = seeded_goal()

      # Force a stored row out of line with history without touching events.
      Repo.update_all(
        from(revision in PlanRevisionRecord,
          where: revision.goal_id == ^goal.id and revision.revision_number == 3
        ),
        set: [status: "proposed"]
      )

      assert {:ok, rebuilt} = Plans.rebuild(goal.id)
      refute rebuilt.consistent?
      assert Enum.any?(rebuilt.divergences, &(&1 =~ "revision 3 status diverges"))
    end

    test "names a stored authority that events do not grant" do
      %{goal: goal} = seeded_goal()

      Repo.update_all(
        from(revision in PlanRevisionRecord,
          where: revision.goal_id == ^goal.id and revision.revision_number == 2
        ),
        set: [status: "superseded"]
      )

      assert {:ok, rebuilt} = Plans.rebuild(goal.id)
      refute rebuilt.consistent?
      assert Enum.any?(rebuilt.divergences, &(&1 =~ "authority"))
    end

    test "rebuild never writes" do
      %{goal: goal} = seeded_goal()

      before = snapshot(goal.id)
      assert {:ok, _rebuilt} = Plans.rebuild(goal.id)
      assert snapshot(goal.id) == before
    end
  end

  defp snapshot(goal_id) do
    revisions =
      Repo.all(
        from revision in PlanRevisionRecord,
          where: revision.goal_id == ^goal_id,
          order_by: [asc: revision.revision_number],
          select: {revision.revision_number, revision.status, revision.digest, revision.content}
      )

    events =
      Repo.all(
        from event in TrajectoryEvent,
          where: event.goal_id == ^goal_id,
          order_by: [asc: event.sequence],
          select: {event.sequence, event.type, event.payload}
      )

    {revisions, events}
  end
end
