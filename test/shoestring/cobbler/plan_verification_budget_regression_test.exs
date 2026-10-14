defmodule Shoestring.Cobbler.PlanVerificationBudgetRegressionTest do
  use Shoestring.DataCase, async: false
  import Shoestring.Test.PlanFanoutHelpers
  alias Shoestring.Cobbler.{PlanFanout, ReservationRecord}

  test "fan-out admission reserves worst-case final-scope verification for each held owner" do
    # A 300s task + 120s global gate fits a 700s goal, but the bounded
    # final-scope observation (59 Git commands at 5s for six attempts) does not.
    c =
      fixture(
        independent_only: true,
        task_seconds: 300,
        goal_seconds: 700,
        reconciliation_opts: [group_probe: fn _ -> :absent end]
      )

    assert {:ok, result} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
    # The baseline dispatches `north` here, leaving no verification allowance.
    assert result.dispatched == []
    assert Enum.all?(result.blocked, &(&1.reason == :fanout_duration_allowance_exhausted))
    assert Repo.aggregate(ReservationRecord, :count) == 0
  end
end
