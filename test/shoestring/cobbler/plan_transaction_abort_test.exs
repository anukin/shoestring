defmodule Shoestring.Cobbler.PlanTransactionAbortTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.Cobbler.{PlanDecisionRecord, PlanRevisionRecord, Plans}
  alias Shoestring.Repo
  alias Shoestring.Test.AbortedPlanRepo
  alias Shoestring.Trajectory.TrajectoryEvent

  import Shoestring.Test.CobblerHelpers, only: [create_goal!: 0]
  import Shoestring.Test.PlanFixtures

  defp abort_opts do
    caller = self()
    [repo: AbortedPlanRepo, publish_fun: fn event -> send(caller, {:published, event}) end]
  end

  test "an aborted proposal returns a structured conflict without writing or publishing" do
    goal = create_goal!()
    before_events = Repo.aggregate(TrajectoryEvent, :count, :id)

    assert {:error, {:database_conflict, %{"kind" => "transaction_aborted"}}} =
             Plans.propose(goal.id, propose_attrs(), abort_opts())

    assert Repo.aggregate(PlanRevisionRecord, :count, :id) == 0
    assert Repo.aggregate(TrajectoryEvent, :count, :id) == before_events
    refute_received {:published, _}
  end

  for decision <- [:approve, :reject] do
    test "an aborted #{decision} preserves the proposed revision and emits no decision" do
      goal = create_goal!()
      assert {:ok, %{revision: revision}} = Plans.propose(goal.id, propose_attrs())
      before_events = Repo.aggregate(TrajectoryEvent, :count, :id)

      attrs =
        case unquote(decision) do
          :approve -> approve_attrs(1, revision.digest)
          :reject -> reject_attrs(1, revision.digest)
        end

      assert {:error, {:database_conflict, %{"kind" => "transaction_aborted"}}} =
               apply(Plans, unquote(decision), [goal.id, attrs, abort_opts()])

      assert Repo.get!(PlanRevisionRecord, revision.id).status == "proposed"
      assert Repo.aggregate(PlanDecisionRecord, :count, :id) == 0
      assert Repo.aggregate(TrajectoryEvent, :count, :id) == before_events
      refute_received {:published, _}
    end
  end

  test "an aborted proposal still resolves an identical durable replay" do
    goal = create_goal!()
    assert {:ok, %{revision: revision}} = Plans.propose(goal.id, propose_attrs())
    before_events = Repo.aggregate(TrajectoryEvent, :count, :id)

    assert {:ok, %{outcome: :replayed, revision: replayed, events: []}} =
             Plans.propose(goal.id, propose_attrs(), abort_opts())

    assert replayed.id == revision.id
    assert Repo.aggregate(PlanRevisionRecord, :count, :id) == 1
    assert Repo.aggregate(TrajectoryEvent, :count, :id) == before_events
    refute_received {:published, _}
  end
end
