defmodule Shoestring.Cobbler.PlansTest do
  @moduledoc """
  Hermetic DataCase tests for the durable plan store: immutable revisions,
  proposal replay and conflict, digest-bound approval, stale and
  cross-goal rejection, bounded rejection reasons, inert supersession,
  retained approved task identities, and an inert slice that dispatches
  nothing.
  """
  use Shoestring.DataCase, async: false

  alias Oban.Job
  alias Shoestring.Cobbler
  alias Shoestring.Cobbler.{PlanDecisionRecord, PlanRevisionRecord, Plans}
  alias Shoestring.Harness.RunRecord
  alias Shoestring.Repo
  alias Shoestring.Trajectory.TrajectoryEvent

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers, only: [create_goal!: 0, create_goal!: 2]
  import Shoestring.Test.PlanFixtures

  @now ~U[2026-09-30 12:00:00.000000Z]
  @later ~U[2026-09-30 13:00:00.000000Z]

  defp opts(extra \\ []), do: Keyword.merge([now: @now, publish_fun: fn _event -> :ok end], extra)

  defp propose!(goal, attrs_opts \\ [], call_opts \\ []) do
    assert {:ok, result} = Plans.propose(goal.id, propose_attrs(attrs_opts), opts(call_opts))
    result
  end

  describe "proposing a revision" do
    test "records revision one with its content, digest, and ordered task ids" do
      goal = create_goal!()

      assert %{revision: revision, outcome: :recorded, events: [event]} = propose!(goal)

      assert revision.revision_number == 1
      assert revision.parent_revision_number == nil
      assert revision.status == "proposed"
      assert revision.author_kind == "human"
      assert revision.authored_by == "human:planner"
      assert revision.task_count == 4
      assert revision.digest =~ ~r/\A[0-9a-f]{64}\z/

      assert event.type == "cobbler.plan.revision.created"
      assert event.payload["revision_number"] == 1
      assert event.payload["plan_digest"] == revision.digest
      assert event.payload["ordered_task_ids"] == ["survey", "widen", "narrow", "verify"]
      assert event.payload["author_kind"] == "human"
    end

    test "replays an identical re-proposal without appending another event" do
      goal = create_goal!()
      %{revision: first} = propose!(goal)

      assert {:ok, %{revision: replayed, outcome: :replayed, events: []}} =
               Plans.propose(goal.id, propose_attrs(), opts())

      assert replayed.id == first.id
      assert Repo.aggregate(PlanRevisionRecord, :count, :id) == 1
      assert plan_event_count(goal.id) == 1
    end

    test "rejects the same proposal id carrying different content" do
      goal = create_goal!()
      propose!(goal)

      edited = plan(%{"goal" => goal(%{"statement" => "A materially different goal."})})

      assert {:error, {:plan_proposal_conflict, detail}} =
               Plans.propose(goal.id, propose_attrs(plan: edited), opts())

      assert detail["proposal_id"] == "proposal-1"
      refute detail["existing_digest"] == detail["incoming_digest"]
      assert Repo.aggregate(PlanRevisionRecord, :count, :id) == 1
    end

    test "rejects an invalid plan before anything is written" do
      goal = create_goal!()

      cyclic =
        plan(%{
          "tasks" => [task("a", "First", ["b"]), task("b", "Second", ["a"])],
          "budget" => %{"max_total_attempts" => 4, "max_total_duration_seconds" => 2_400}
        })

      assert {:error, {:invalid_graph, {:cycle, _witness}}} =
               Plans.propose(goal.id, propose_attrs(plan: cyclic), opts())

      assert Repo.aggregate(PlanRevisionRecord, :count, :id) == 0
      assert plan_event_count(goal.id) == 0
    end

    test "rejects a non-human author" do
      goal = create_goal!()

      for author <- ["system:planner", "model:fixture", "planner"] do
        assert {:error, {:non_human_identity, %{"field" => :authored_by}}} =
                 Plans.propose(goal.id, propose_attrs(authored_by: author), opts())
      end

      assert Repo.aggregate(PlanRevisionRecord, :count, :id) == 0
    end

    test "rejects a proposal for a goal that does not exist" do
      assert {:error, :goal_not_found} =
               Plans.propose(Ecto.UUID.generate(), propose_attrs(), opts())
    end
  end

  describe "editing creates a new immutable revision" do
    test "preserves the earlier revision byte for byte" do
      goal = create_goal!()
      %{revision: first} = propose!(goal)
      original_content = first.content
      original_digest = first.digest

      rewired =
        plan(%{
          "tasks" => [
            task("survey", "Survey the existing contract surface", []),
            task("widen", "Widen validation to cover dependency references", ["survey"]),
            task("narrow", "Narrow acceptance to named trusted gates", ["widen"]),
            task("verify", "Verify replay reproduces the digest", ["narrow"])
          ]
        })

      %{revision: second} =
        propose!(goal, proposal_id: "proposal-2", plan: rewired, parent_revision_number: 1)

      assert second.revision_number == 2
      assert second.parent_revision_number == 1
      refute second.digest == original_digest

      reloaded = Plans.get_revision(goal.id, 1)
      assert reloaded.content == original_content
      assert reloaded.digest == original_digest
      assert reloaded.status == "proposed"
    end

    test "requires a later revision to name the revision it was edited from" do
      goal = create_goal!()
      propose!(goal)

      assert {:error, {:plan_parent_required, %{"revision_number" => 2}}} =
               Plans.propose(goal.id, propose_attrs(proposal_id: "proposal-2"), opts())
    end

    test "rejects a first revision that claims a parent" do
      goal = create_goal!()

      assert {:error, {:plan_parent_not_found, %{"parent_revision_number" => 1}}} =
               Plans.propose(goal.id, propose_attrs(parent_revision_number: 1), opts())
    end

    test "rejects a parent that belongs to a different goal" do
      goal = create_goal!()
      other = create_goal!(Repo, "Another goal")
      propose!(other)

      assert {:error, {:plan_parent_not_found, _detail}} =
               Plans.propose(
                 goal.id,
                 propose_attrs(proposal_id: "proposal-x", parent_revision_number: 1),
                 opts()
               )
    end
  end

  describe "approval binds an exact revision and digest" do
    setup do
      goal = create_goal!()
      %{revision: revision} = propose!(goal)
      %{goal: goal, revision: revision}
    end

    test "approves the named revision and makes it the single authority", %{
      goal: goal,
      revision: revision
    } do
      assert {:ok, %{revision: approved, decision: decision, outcome: :recorded, events: [event]}} =
               Plans.approve(goal.id, approve_attrs(1, revision.digest), opts())

      assert approved.status == "approved"
      assert decision.kind == "approve"
      assert decision.bound_digest == revision.digest
      assert decision.decided_by == "human:approver"

      assert event.type == "cobbler.plan.approved"
      assert event.payload["plan_digest"] == revision.digest
      refute Map.has_key?(event.payload, "superseded_revision_number")

      authority = Plans.authority(goal.id)
      assert authority.revision_number == 1
      assert authority.digest == revision.digest
      assert authority.ordered_task_ids == ["survey", "widen", "narrow", "verify"]
    end

    test "refuses an approval carrying a digest the revision never had", %{goal: goal} do
      stale = String.duplicate("a", 64)

      assert {:error, {:plan_digest_mismatch, detail}} =
               Plans.approve(goal.id, approve_attrs(1, stale), opts())

      assert detail["provided"] == stale
      assert Plans.authority(goal.id) == nil
      assert Repo.aggregate(PlanDecisionRecord, :count, :id) == 0
    end

    test "refuses an approval carrying the digest of a superseded edit", %{
      goal: goal,
      revision: revision
    } do
      %{revision: second} =
        propose!(goal,
          proposal_id: "proposal-2",
          parent_revision_number: 1,
          plan: plan(%{"goal" => goal(%{"statement" => "The edited goal statement."})})
        )

      # The operator is still looking at revision 1's digest but names
      # revision 2: the content they read is not the content they would
      # authorize.
      assert {:error, {:plan_digest_mismatch, detail}} =
               Plans.approve(goal.id, approve_attrs(2, revision.digest), opts())

      assert detail["expected"] == second.digest
      assert detail["provided"] == revision.digest
      assert Plans.authority(goal.id) == nil
    end

    test "refuses a revision that already carries a decision", %{goal: goal, revision: revision} do
      assert {:ok, _result} = Plans.approve(goal.id, approve_attrs(1, revision.digest), opts())

      assert {:error, {:plan_revision_not_pending, %{"status" => "approved"}}} =
               Plans.approve(
                 goal.id,
                 approve_attrs(1, revision.digest, decision_id: "decision-2"),
                 opts()
               )

      assert Repo.aggregate(PlanDecisionRecord, :count, :id) == 1
    end

    test "refuses a revision number that belongs to a different goal", %{revision: revision} do
      other = create_goal!(Repo, "Another goal")

      assert {:error, {:plan_revision_not_found, %{"revision_number" => 1}}} =
               Plans.approve(other.id, approve_attrs(1, revision.digest), opts())
    end

    test "refuses an approver who is not a human identity", %{goal: goal, revision: revision} do
      for approver <- ["system:dispatcher", "model:fixture_planner"] do
        assert {:error, {:non_human_identity, %{"field" => :decided_by}}} =
                 Plans.approve(
                   goal.id,
                   approve_attrs(1, revision.digest, decided_by: approver),
                   opts()
                 )
      end

      assert Plans.authority(goal.id) == nil
    end

    test "refuses a reason on an approval instead of silently dropping it", %{
      goal: goal,
      revision: revision
    } do
      attrs = approve_attrs(1, revision.digest) |> Map.put(:reason, "Looks fine.")

      assert {:error, {:invalid_plan_request, :reason, _message}} =
               Plans.approve(goal.id, attrs, opts())
    end
  end

  describe "repeated and conflicting decisions" do
    setup do
      goal = create_goal!()
      %{revision: revision} = propose!(goal)
      %{goal: goal, revision: revision}
    end

    test "replays an identical approval without a second event or a second decision", %{
      goal: goal,
      revision: revision
    } do
      assert {:ok, %{outcome: :recorded}} =
               Plans.approve(goal.id, approve_attrs(1, revision.digest), opts())

      assert {:ok, %{outcome: :replayed, events: [], revision: replayed}} =
               Plans.approve(goal.id, approve_attrs(1, revision.digest), opts(now: @later))

      assert replayed.status == "approved"
      assert Repo.aggregate(PlanDecisionRecord, :count, :id) == 1
      assert approved_event_count(goal.id) == 1
    end

    test "refuses to reuse a decision id for a different revision", %{
      goal: goal,
      revision: revision
    } do
      %{revision: second} =
        propose!(goal,
          proposal_id: "proposal-2",
          parent_revision_number: 1,
          plan: plan(%{"goal" => goal(%{"statement" => "The edited goal statement."})})
        )

      assert {:ok, _result} = Plans.approve(goal.id, approve_attrs(1, revision.digest), opts())

      assert {:error, {:plan_decision_conflict, detail}} =
               Plans.approve(goal.id, approve_attrs(2, second.digest), opts())

      assert detail["existing"]["revision_number"] == 1
      assert detail["incoming"]["revision_number"] == 2
      assert Plans.authority(goal.id).revision_number == 1
    end

    test "refuses to reuse a decision id to flip an approval into a rejection", %{
      goal: goal,
      revision: revision
    } do
      assert {:ok, _result} = Plans.approve(goal.id, approve_attrs(1, revision.digest), opts())

      assert {:error, {:plan_decision_conflict, detail}} =
               Plans.reject(goal.id, reject_attrs(1, revision.digest), opts())

      assert detail["existing"]["kind"] == "approve"
      assert detail["incoming"]["kind"] == "reject"
      assert Plans.authority(goal.id).revision_number == 1
    end
  end

  describe "rejection" do
    setup do
      goal = create_goal!()
      %{revision: revision} = propose!(goal)
      %{goal: goal, revision: revision}
    end

    test "records a bounded reason and grants no authority", %{goal: goal, revision: revision} do
      assert {:ok, %{revision: rejected, decision: decision, events: [event]}} =
               Plans.reject(goal.id, reject_attrs(1, revision.digest), opts())

      assert rejected.status == "rejected"
      assert decision.kind == "reject"
      assert decision.reason == "The dependency order does not match the repository."
      assert event.type == "cobbler.plan.rejected"
      assert event.payload["reason"] == decision.reason
      assert Plans.authority(goal.id) == nil
    end

    test "requires a reason", %{goal: goal, revision: revision} do
      attrs = reject_attrs(1, revision.digest) |> Map.delete(:reason)

      assert {:error, {:invalid_plan_request, :reason, _message}} =
               Plans.reject(goal.id, attrs, opts())

      assert Plans.get_revision(goal.id, 1).status == "proposed"
    end

    test "refuses an unbounded reason rather than truncating it", %{
      goal: goal,
      revision: revision
    } do
      attrs = reject_attrs(1, revision.digest, reason: String.duplicate("x", 501))

      assert {:error, {:invalid_plan_request, :reason, _message}} =
               Plans.reject(goal.id, attrs, opts())
    end

    test "a rejected revision can be edited into a new revision", %{
      goal: goal,
      revision: revision
    } do
      assert {:ok, _result} = Plans.reject(goal.id, reject_attrs(1, revision.digest), opts())

      %{revision: second} =
        propose!(goal,
          proposal_id: "proposal-2",
          parent_revision_number: 1,
          plan: plan(%{"goal" => goal(%{"statement" => "The corrected goal statement."})})
        )

      assert second.revision_number == 2
      assert Plans.get_revision(goal.id, 1).status == "rejected"
    end
  end

  describe "supersession" do
    test "approving a newer revision supersedes the older authority and nothing else" do
      goal = create_goal!()
      %{revision: first} = propose!(goal)
      assert {:ok, _result} = Plans.approve(goal.id, approve_attrs(1, first.digest), opts())

      %{revision: second} =
        propose!(goal,
          proposal_id: "proposal-2",
          parent_revision_number: 1,
          plan: plan(%{"goal" => goal(%{"statement" => "The edited goal statement."})})
        )

      assert {:ok, %{superseded: superseded, events: [event]}} =
               Plans.approve(
                 goal.id,
                 approve_attrs(2, second.digest, decision_id: "decision-2"),
                 opts(now: @later)
               )

      assert superseded.revision_number == 1
      assert superseded.status == "superseded"
      assert event.payload["superseded_revision_number"] == 1
      assert event.payload["superseded_revision_id"] == first.id

      assert Plans.authority(goal.id).revision_number == 2
      assert Plans.get_revision(goal.id, 1).status == "superseded"

      # Supersession is inert: it cancels nothing and enqueues nothing.
      assert Repo.aggregate(Job, :count, :id) == 0
      assert Repo.aggregate(RunRecord, :count, :id) == 0
    end

    test "a superseded revision keeps its exact content and digest" do
      goal = create_goal!()
      %{revision: first} = propose!(goal)
      original_content = first.content
      assert {:ok, _result} = Plans.approve(goal.id, approve_attrs(1, first.digest), opts())

      %{revision: second} =
        propose!(goal,
          proposal_id: "proposal-2",
          parent_revision_number: 1,
          plan: plan(%{"goal" => goal(%{"statement" => "The edited goal statement."})})
        )

      assert {:ok, _result} =
               Plans.approve(
                 goal.id,
                 approve_attrs(2, second.digest, decision_id: "decision-2"),
                 opts(now: @later)
               )

      reloaded = Plans.get_revision(goal.id, 1)
      assert reloaded.content == original_content
      assert reloaded.digest == first.digest
    end

    test "refuses to approve a revision older than the one holding authority" do
      goal = create_goal!()
      %{revision: first} = propose!(goal)

      %{revision: second} =
        propose!(goal,
          proposal_id: "proposal-2",
          parent_revision_number: 1,
          plan: plan(%{"goal" => goal(%{"statement" => "The edited goal statement."})})
        )

      assert {:ok, _result} =
               Plans.approve(goal.id, approve_attrs(2, second.digest), opts())

      assert {:error, {:plan_revision_stale, detail}} =
               Plans.approve(
                 goal.id,
                 approve_attrs(1, first.digest, decision_id: "decision-2"),
                 opts(now: @later)
               )

      assert detail["approved_revision_number"] == 2
      assert detail["requested_revision_number"] == 1
      assert Plans.authority(goal.id).revision_number == 2
    end
  end

  describe "approved task identities are stable" do
    setup do
      goal = create_goal!()
      %{revision: revision} = propose!(goal)
      assert {:ok, _result} = Plans.approve(goal.id, approve_attrs(1, revision.digest), opts())
      %{goal: goal, revision: revision}
    end

    test "refuses an edit that drops a task id approved history introduced", %{goal: goal} do
      shrunk =
        plan(%{
          "tasks" => [
            task("survey", "Survey the existing contract surface", []),
            task("widen", "Widen validation to cover dependency references", ["survey"])
          ],
          "budget" => %{"max_total_attempts" => 4, "max_total_duration_seconds" => 2_400}
        })

      assert {:error, {:approved_task_identity_dropped, %{"missing" => missing}}} =
               Plans.propose(
                 goal.id,
                 propose_attrs(
                   proposal_id: "proposal-2",
                   parent_revision_number: 1,
                   plan: shrunk
                 ),
                 opts()
               )

      assert missing == ["narrow", "verify"]
      assert Repo.aggregate(PlanRevisionRecord, :count, :id) == 1
    end

    test "allows an edit that changes a task but keeps its identity", %{goal: goal} do
      edited =
        plan(%{
          "tasks" => [
            task("survey", "Survey the existing contract surface", []),
            task("widen", "Widen validation much further than before", ["survey"]),
            task("narrow", "Narrow acceptance to named trusted gates", ["survey"]),
            task("verify", "Verify replay reproduces the digest", ["widen", "narrow"])
          ]
        })

      assert {:ok, %{revision: second}} =
               Plans.propose(
                 goal.id,
                 propose_attrs(
                   proposal_id: "proposal-2",
                   parent_revision_number: 1,
                   plan: edited
                 ),
                 opts(now: @later)
               )

      assert second.task_count == 4
    end

    test "allows an edit that adds a task on top of approved identities", %{goal: goal} do
      extended =
        plan(%{
          "tasks" => tasks() ++ [task("document", "Document the plan contract", ["verify"])],
          "budget" => %{"max_total_attempts" => 14, "max_total_duration_seconds" => 8_400}
        })

      assert {:ok, %{revision: second}} =
               Plans.propose(
                 goal.id,
                 propose_attrs(
                   proposal_id: "proposal-2",
                   parent_revision_number: 1,
                   plan: extended
                 ),
                 opts(now: @later)
               )

      assert second.task_count == 5
    end

    test "a goal whose plan was never approved may drop a task freely" do
      fresh = create_goal!(Repo, "Never approved")
      propose!(fresh)

      shrunk =
        plan(%{
          "tasks" => [task("survey", "Survey the existing contract surface", [])],
          "budget" => %{"max_total_attempts" => 2, "max_total_duration_seconds" => 1_200}
        })

      assert {:ok, %{revision: second}} =
               Plans.propose(
                 fresh.id,
                 propose_attrs(
                   proposal_id: "proposal-2",
                   parent_revision_number: 1,
                   plan: shrunk
                 ),
                 opts()
               )

      assert second.task_count == 1
    end
  end

  describe "the slice is inert" do
    test "proposing, approving, and rejecting dispatch nothing" do
      goal = create_goal!()
      %{revision: first} = propose!(goal)
      assert {:ok, _result} = Plans.approve(goal.id, approve_attrs(1, first.digest), opts())

      other = create_goal!(Repo, "Rejected goal")
      %{revision: second} = propose!(other)
      assert {:ok, _result} = Plans.reject(other.id, reject_attrs(1, second.digest), opts())

      assert Repo.aggregate(Job, :count, :id) == 0
      assert Repo.aggregate(RunRecord, :count, :id) == 0

      # No lease, claim, or command row appeared either.
      assert Repo.aggregate(Shoestring.Cobbler.TaskClaimRecord, :count, :id) == 0
      assert Repo.aggregate(Shoestring.Cobbler.CommandRecord, :count, :id) == 0
    end

    test "only the three plan event types are ever appended" do
      goal = create_goal!()
      %{revision: revision} = propose!(goal)
      assert {:ok, _result} = Plans.approve(goal.id, approve_attrs(1, revision.digest), opts())

      types =
        Repo.all(
          from event in TrajectoryEvent, where: event.goal_id == ^goal.id, select: event.type
        )

      assert Enum.sort(types) == ["cobbler.plan.approved", "cobbler.plan.revision.created"]
      assert Enum.all?(types, &(&1 in Plans.event_types()))
    end
  end

  describe "the domain entrypoint is reachable without a LiveView" do
    test "the Cobbler facade exposes the whole plan lifecycle" do
      goal = create_goal!()

      assert {:ok, contract} = Cobbler.build_plan(plan())

      assert {:ok, %{revision: revision}} =
               Cobbler.propose_plan(goal.id, propose_attrs(), opts())

      assert revision.digest == contract.digest

      assert {:ok, %{revision: approved}} =
               Cobbler.approve_plan(goal.id, approve_attrs(1, revision.digest), opts())

      assert approved.status == "approved"
      assert Cobbler.plan_authority(goal.id).revision_number == 1
      assert [%PlanRevisionRecord{}] = Cobbler.list_plan_revisions(goal.id)
      assert [%PlanDecisionRecord{}] = Cobbler.list_plan_decisions(goal.id)
      assert Cobbler.plan_revision(goal.id, 1).id == revision.id
      assert {:ok, %{consistent?: true}} = Cobbler.rebuild_plans(goal.id)
    end
  end

  defp plan_event_count(goal_id) do
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
