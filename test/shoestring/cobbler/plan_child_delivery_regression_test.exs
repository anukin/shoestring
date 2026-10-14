defmodule Shoestring.Cobbler.PlanChildDeliveryRegressionTest do
  use Shoestring.DataCase, async: false
  import Shoestring.Test.PlanFanoutHelpers
  alias Shoestring.Cobbler.{PlanExecutor, PlanFanout}
  alias Shoestring.Harness.RunRecord
  alias Shoestring.Trajectory.TrajectoryEvent

  test "a committed later-child completion queues durable Cobbler delivery without manual resume" do
    c = fixture()
    assert {:ok, result} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
    [north, south] = result.dispatched
    complete_child!(c.goal, south.run_id)
    terminal = Repo.get_by!(TrajectoryEvent, type: "run.completed", run_id: south.run_id)

    jobs =
      Repo.all(
        from j in Oban.Job,
          where:
            j.worker == "Shoestring.Cobbler.PlanChildWorker" and
              fragment("json_extract(?, '$.event_id')", j.args) == ^terminal.id
      )

    # This is the baseline behavioral assertion: the old writer creates no job.
    assert [job] = jobs
    previous = Application.get_env(:shoestring, :plan_child_inbox_opts, [])
    on_exit(fn -> Application.put_env(:shoestring, :plan_child_inbox_opts, previous) end)

    Application.put_env(
      :shoestring,
      :plan_child_inbox_opts,
      Keyword.put(c.opts, :reconciliation_opts, group_probe: fn _ -> :absent end)
    )

    assert {:ok, worker} = Oban.Worker.from_string(job.worker)
    assert :ok = apply(worker, :perform, [job])

    assert {:ok, %{accepted: ["south"], active_run_id: id, total_attempts: 2}} =
             PlanExecutor.status(c.goal.id, c.opts)

    assert id == north.run_id
    assert Repo.aggregate(RunRecord, :count) == 2
  end
end
