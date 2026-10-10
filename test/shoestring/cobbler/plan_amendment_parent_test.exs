defmodule Shoestring.Cobbler.PlanAmendmentParentTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.Cobbler.Plans
  alias Shoestring.Test.{CobblerHelpers, PlanFixtures}
  import Shoestring.Test.PlanExecutorHelpers

  @tag :amendment_parent_regression
  test "a reviewed parent digest cannot bind a different approved revision" do
    goal = CobblerHelpers.create_goal!()
    first = propose_and_approve!(goal)

    assert {:ok, %{revision: newer}} =
             Plans.propose(
               goal.id,
               PlanFixtures.propose_attrs(
                 plan: chain_plan(),
                 parent_revision_number: 1,
                 proposal_id: "newer"
               ),
               exec_opts()
             )

    assert {:ok, _} =
             Plans.approve(
               goal.id,
               PlanFixtures.approve_attrs(2, newer.digest, decision_id: "approve-2"),
               exec_opts()
             )

    attrs =
      PlanFixtures.propose_attrs(
        plan: chain_plan(),
        parent_revision_number: 1,
        proposal_id: "stale-amendment"
      )
      |> Map.put(:parent_digest, first.digest)

    assert {:error, :amendment_parent_changed} = Plans.propose(goal.id, attrs, exec_opts())
    assert length(Plans.list_revisions(goal.id)) == 2
  end

  @tag :amendment_parent_regression
  test "a stale parent digest is refused inside the proposal transaction" do
    goal = CobblerHelpers.create_goal!()
    propose_and_approve!(goal)

    attrs =
      PlanFixtures.propose_attrs(
        plan: chain_plan(),
        parent_revision_number: 1,
        proposal_id: "bad-digest"
      )
      |> Map.put(:parent_digest, String.duplicate("f", 64))

    assert {:error, :amendment_parent_changed} = Plans.propose(goal.id, attrs, exec_opts())
    assert length(Plans.list_revisions(goal.id)) == 1
  end

  test "identical recorded adoption remains replayable after authority moves" do
    goal = CobblerHelpers.create_goal!()
    first = propose_and_approve!(goal)

    attrs =
      PlanFixtures.propose_attrs(
        plan: chain_plan(),
        parent_revision_number: 1,
        proposal_id: "exact-parent"
      )
      |> Map.put(:parent_digest, first.digest)

    assert {:ok, %{revision: revision}} = Plans.propose(goal.id, attrs, exec_opts())

    assert {:ok, _} =
             Plans.approve(
               goal.id,
               PlanFixtures.approve_attrs(2, revision.digest, decision_id: "approve-2"),
               exec_opts()
             )

    assert {:ok, %{outcome: :replayed, revision: replay}} =
             Plans.propose(goal.id, attrs, exec_opts())

    assert replay.id == revision.id
    assert length(Plans.list_revisions(goal.id)) == 2
  end
end
