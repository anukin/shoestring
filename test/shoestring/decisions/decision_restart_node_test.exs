defmodule Shoestring.Decisions.DecisionRestartNodeTest do
  @moduledoc """
  Iteration 19: a pending decision survives a real application restart and
  is still answerable, on an isolated node with pooled SQLite (no sandbox).
  While it waits, the boot repair does not queue the plan; the answer does.
  """
  use ExUnit.Case, async: false

  if System.get_env("SHOESTRING_DECISION_RESTART_CHILD") == "1" do
    import Ecto.Query
    import Shoestring.Test.DecisionHelpers
    import Shoestring.Test.FanoutNodeHelpers, only: [configure_node!: 0, restart!: 0]

    alias Shoestring.{Cobbler, Decisions, Repo}
    alias Shoestring.Cobbler.ExecutionControl
    alias Shoestring.Decisions.Decision
    alias Shoestring.Test.{CobblerHelpers, PlanExecutorHelpers}

    setup do
      configure_node!()
      :ok
    end

    defp execution_jobs(goal_id) do
      Repo.all(
        from j in Oban.Job,
          where: j.worker == "Shoestring.Cobbler.PlanExecutionWorker" and j.state == "available"
      )
      |> Enum.filter(&(&1.args["goal_id"] == goal_id))
    end

    test "a pending decision survives a restart, is still answerable, and the answer resumes the plan" do
      goal = CobblerHelpers.create_goal!()
      worktree = Path.join(System.tmp_dir!(), "decision-restart-#{Ecto.UUID.generate()}")
      File.mkdir_p!(worktree)
      on_exit(fn -> File.rm_rf(worktree) end)
      write_candidates!(worktree)

      assert %{disposition: :accepted} =
               run_sheets!(goal, worktree, decision_plan(), repository_path: worktree)

      assert [%Decision{state: "pending"} = decision] = Decisions.list(goal_ids: [goal.id])

      restart!()

      # Still pending after the restart, with its candidates intact.
      assert %Decision{state: "pending"} = Decisions.get(decision.id)

      for option <- decision.options,
          do: assert({:ok, _} = Shoestring.Trajectory.ArtifactStore.read(option["artifact_id"]))

      assert {:ok, %{awaiting_decision: ["sheets"], needs_user?: true}} =
               Cobbler.plan_execution_status(goal.id)

      # Boot repair waits for the person: nothing is queued.
      assert {:ok, %{outcome: :needs_user}} =
               ExecutionControl.continue(goal.id, decision.execution_id)

      assert execution_jobs(goal.id) == []

      # The answer, after the restart, queues the plan again.
      assert {:ok, %Decision{state: "answered"}} =
               Decisions.answer(decision.id, "blue", nil, "human:test")

      assert [_job] = execution_jobs(goal.id)

      assert {:ok, %{disposition: :dispatched, plan_task_id: "story"}} =
               Cobbler.advance_plan_execution(
                 goal.id,
                 opts(worktree, admission_event_id: PlanExecutorHelpers.admit!(goal).id)
               )
    end
  else
    @tag timeout: 240_000
    test "decision restart scenario on an isolated node" do
      root = Path.join(File.cwd!(), ".shoestring/decision-restart-#{Ecto.UUID.generate()}")

      {output, status} =
        System.cmd(
          "python3",
          [
            "-c",
            "import subprocess,sys; r=subprocess.run(['mix','test',sys.argv[1],'--seed','0'],stdin=subprocess.DEVNULL,timeout=200); sys.exit(r.returncode)",
            "test/shoestring/decisions/decision_restart_node_test.exs"
          ],
          env: [{"SHOESTRING_DECISION_RESTART_CHILD", "1"}, {"SHOESTRING_TEST_STATE_DIR", root}],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "1 test, 0 failures"
    end
  end
end
