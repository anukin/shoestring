defmodule Shoestring.Cobbler.TransactionAbortTest do
  @moduledoc """
  Hermetic regressions for the shared transaction helpers'
  (`Plans.run_transaction/2`, `Planner.run_transaction/2`) bare-abort leak.

  `Shoestring.Test.AbortRepo` executes the statements genuinely and then
  reports the bare `{:error, :rollback}` an aborted adapter conclude
  returns — deterministically, with no sleeps and no timing. The helpers
  must normalize only that bare abort into the existing structured
  `database_busy` error: intentional domain rollback reasons pass through
  unchanged, and nothing aborted is persisted.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Cobbler
  alias Shoestring.Cobbler.Plans
  alias Shoestring.Test.{AbortRepo, PlanFixtures, PlannerCallLog, PlannerHelpers}

  import Shoestring.Test.PlanFixtures, only: [propose_attrs: 0, propose_attrs: 1]

  setup do
    goal = PlannerHelpers.create_goal!()
    log = PlannerHelpers.start_log!()
    {:ok, %{goal: goal, log: log}}
  end

  describe "Plans.run_transaction/2" do
    test "a bare adapter abort becomes a structured database_busy with nothing persisted", %{
      goal: goal
    } do
      assert {:error, {:database_busy, message}} =
               Plans.propose(goal.id, propose_attrs(), repo: AbortRepo)

      assert is_binary(message) and message != ""
      assert Cobbler.list_plan_revisions(goal.id) == []
    end

    test "an intentional domain rollback reason passes through unchanged", %{goal: goal} do
      assert {:ok, _first} = Plans.propose(goal.id, propose_attrs())

      conflicting =
        propose_attrs(
          plan:
            PlanFixtures.plan(%{
              "goal" => PlanFixtures.goal(%{"statement" => "A different but valid goal."})
            })
        )

      assert {:error, {:plan_proposal_conflict, detail}} =
               Plans.propose(goal.id, conflicting, repo: AbortRepo)

      assert detail["proposal_id"] == "proposal-1"
    end
  end

  describe "Planner.run_transaction/2" do
    test "a bare adapter abort becomes a structured database_busy with zero accounting", %{
      goal: goal,
      log: log
    } do
      opts = PlannerHelpers.call_opts(log, PlannerHelpers.admitted_snapshot(), repo: AbortRepo)

      assert {:error, {:database_busy, message}} =
               Cobbler.request_plan(goal.id, PlannerHelpers.request_attrs(), opts)

      assert is_binary(message) and message != ""
      assert Cobbler.list_planner_requests(goal.id) == []
      assert Cobbler.list_plan_revisions(goal.id) == []
      assert PlannerCallLog.count(log) == 0
    end
  end
end
