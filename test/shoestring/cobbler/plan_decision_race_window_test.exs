defmodule Shoestring.Cobbler.PlanDecisionRaceWindowTest do
  @moduledoc """
  Regression lock for the read-then-write window in the decision store.

  `Plans.decide/4` reads `cobbler_plan_decisions` to detect a replay and
  then inserts. `mode: :immediate` closes that window only on a connection
  that actually takes SQLite's write lock; inside an enclosing transaction
  Exqlite issues a SAVEPOINT instead and nothing serializes the read
  against the write.

  These tests drive the losing interleaving deterministically through
  `Shoestring.Test.RacingPlanRepo` — no concurrency, no sleeping, no
  retrying. They assert the two guarantees that must survive it:
  idempotency (a lost race converges on the winner's row) and structured
  errors (nothing raises out of the API).

  Fully hermetic: no provider CLI, no network, no execution.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Cobbler.{PlanDecisionRecord, PlanRevisionRecord, Plans}
  alias Shoestring.Repo
  alias Shoestring.Test.RacingPlanRepo
  alias Shoestring.Trajectory.TrajectoryEvent

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers, only: [create_goal!: 0]
  import Shoestring.Test.PlanFixtures

  @now ~U[2026-09-30 12:00:00.000000Z]
  @later ~U[2026-09-30 13:00:00.000000Z]

  defp opts(extra \\ []), do: Keyword.merge([now: @now, publish_fun: fn _event -> :ok end], extra)

  setup do
    goal = create_goal!()

    assert {:ok, %{revision: revision}} = Plans.propose(goal.id, propose_attrs(), opts())

    %{goal: goal, revision: revision}
  end

  describe "a decision that loses the idempotency race" do
    test "converges on the winner's row instead of reporting a storage failure", %{
      goal: goal,
      revision: revision
    } do
      attrs = approve_attrs(1, revision.digest, decision_id: "decision-raced")

      assert {:ok, %{outcome: :recorded, decision: winner}} =
               Plans.approve(goal.id, attrs, opts())

      # The loser's replay lookup misses the winner's row, so it takes the
      # record path and its INSERT meets the (goal_id, decision_id) index.
      RacingPlanRepo.lose_next_decision_read()

      assert {:ok, %{outcome: :replayed, decision: replayed, revision: approved}} =
               Plans.approve(goal.id, attrs, opts(repo: RacingPlanRepo, now: @later))

      refute RacingPlanRepo.armed?()
      assert replayed.id == winner.id
      assert approved.status == "approved"
    end

    test "writes nothing extra: one decision, one event, one authority", %{
      goal: goal,
      revision: revision
    } do
      attrs = approve_attrs(1, revision.digest, decision_id: "decision-raced")

      assert {:ok, %{outcome: :recorded}} = Plans.approve(goal.id, attrs, opts())

      RacingPlanRepo.lose_next_decision_read()

      assert {:ok, %{outcome: :replayed, events: []}} =
               Plans.approve(goal.id, attrs, opts(repo: RacingPlanRepo, now: @later))

      assert Repo.aggregate(PlanDecisionRecord, :count, :id) == 1
      assert approved_event_count(goal.id) == 1

      assert Repo.aggregate(
               from(r in PlanRevisionRecord, where: r.status == "approved"),
               :count,
               :id
             ) == 1

      assert Plans.authority(goal.id).revision_number == 1
    end

    test "still refuses a genuine conflict rather than converging on it", %{
      goal: goal,
      revision: revision
    } do
      assert {:ok, _result} =
               Plans.approve(
                 goal.id,
                 approve_attrs(1, revision.digest, decision_id: "decision-raced"),
                 opts()
               )

      # Same decision id, but this caller wants a REJECTION. Losing the race
      # must not launder that into "your rejection was already recorded".
      RacingPlanRepo.lose_next_decision_read()

      assert {:error, {:plan_decision_conflict, detail}} =
               Plans.reject(
                 goal.id,
                 reject_attrs(1, revision.digest, decision_id: "decision-raced"),
                 opts(repo: RacingPlanRepo, now: @later)
               )

      assert detail["existing"]["kind"] == "approve"
      assert detail["incoming"]["kind"] == "reject"
      assert Plans.authority(goal.id).revision_number == 1
    end

    test "a second decision id for an already decided revision is still refused", %{
      goal: goal,
      revision: revision
    } do
      assert {:ok, _result} =
               Plans.approve(
                 goal.id,
                 approve_attrs(1, revision.digest, decision_id: "decision-first"),
                 opts()
               )

      # A different decision id cannot claim a revision that is spoken for,
      # and the refusal names the revision rather than leaking a changeset.
      assert {:error, {:plan_revision_not_pending, detail}} =
               Plans.approve(
                 goal.id,
                 approve_attrs(1, revision.digest, decision_id: "decision-second"),
                 opts(now: @later)
               )

      assert detail["revision_number"] == 1
      assert Repo.aggregate(PlanDecisionRecord, :count, :id) == 1
    end
  end

  describe "the twin window on the propose side" do
    test "a proposal that loses its idempotency race converges on the winner's row", %{
      goal: goal,
      revision: revision
    } do
      # Re-proposing the same proposal id with the same content is a replay.
      # Here its replay lookup misses the winner, so it takes the record
      # path and its INSERT meets the (goal_id, proposal_id) index.
      RacingPlanRepo.lose_next_revision_read()

      assert {:ok, %{outcome: :replayed, revision: replayed}} =
               Plans.propose(goal.id, propose_attrs(), opts(repo: RacingPlanRepo, now: @later))

      refute RacingPlanRepo.armed?()
      assert replayed.id == revision.id
      assert Repo.aggregate(PlanRevisionRecord, :count, :id) == 1
      assert revision_created_event_count(goal.id) == 1
    end

    test "a proposal that loses the race on DIFFERENT content is still a conflict", %{goal: goal} do
      RacingPlanRepo.lose_next_revision_read()

      edited = plan(%{"goal" => goal(%{"statement" => "A materially different goal."})})

      # The parent is supplied so that the ONLY thing wrong with this
      # request is the conflicting reuse of the proposal id; otherwise the
      # stale read would make it fail as a parentless second revision
      # before the index ever sees it.
      assert {:error, {:plan_proposal_conflict, detail}} =
               Plans.propose(
                 goal.id,
                 propose_attrs(plan: edited, parent_revision_number: 1),
                 opts(repo: RacingPlanRepo, now: @later)
               )

      assert detail["proposal_id"] == "proposal-1"
      refute detail["existing_digest"] == detail["incoming_digest"]
      assert Repo.aggregate(PlanRevisionRecord, :count, :id) == 1
    end
  end

  describe "the structured-error contract holds against storage raises" do
    test "a storage exception becomes a structured conflict, not a crash", %{
      goal: goal,
      revision: revision
    } do
      Shoestring.Test.RaisingWriteRepo.raise_next_write(:stale)

      assert {:error, {:database_conflict, detail}} =
               Plans.approve(
                 goal.id,
                 approve_attrs(1, revision.digest),
                 opts(repo: Shoestring.Test.RaisingWriteRepo)
               )

      assert detail["kind"] == "Ecto.StaleEntryError"

      # The transaction rolled back whole: no decision, no authority.
      assert Repo.aggregate(PlanDecisionRecord, :count, :id) == 0
      assert Plans.authority(goal.id) == nil
    end

    test "a programming error still crashes loudly instead of being laundered", %{
      goal: goal,
      revision: revision
    } do
      Shoestring.Test.RaisingWriteRepo.raise_next_write(:runtime)

      assert_raise RuntimeError, ~r/not a storage exception/, fn ->
        Plans.approve(
          goal.id,
          approve_attrs(1, revision.digest),
          opts(repo: Shoestring.Test.RaisingWriteRepo)
        )
      end

      assert Repo.aggregate(PlanDecisionRecord, :count, :id) == 0
    end
  end

  defp revision_created_event_count(goal_id) do
    Repo.aggregate(
      from(event in TrajectoryEvent,
        where: event.goal_id == ^goal_id and event.type == "cobbler.plan.revision.created"
      ),
      :count,
      :id
    )
  end

  defp approved_event_count(goal_id) do
    Repo.aggregate(
      from(event in TrajectoryEvent,
        where: event.goal_id == ^goal_id and event.type == "cobbler.plan.approved"
      ),
      :count,
      :id
    )
  end
end
