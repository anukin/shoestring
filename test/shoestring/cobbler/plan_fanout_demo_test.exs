defmodule Shoestring.Cobbler.PlanFanoutDemoTest do
  @moduledoc """
  The iteration-7 demo, driven through the production fan-out driver with live
  supervised Fake Elves on an isolated node. Set `SHOESTRING_FANOUT_DEMO_REPORT`
  to write the step transcript (no identifiers or paths) as JSON.
  """
  use ExUnit.Case, async: false

  if System.get_env("SHOESTRING_FANOUT_DEMO_CHILD") == "1" do
    import Shoestring.Test.PlanFanoutHelpers
    import Shoestring.Test.FanoutNodeHelpers

    alias Shoestring.Cobbler.{PlanExecutor, PlanFanout, PlanFanoutDriver, Reservations}
    alias Shoestring.Harness.Fake
    alias Shoestring.Test.PlanExecutorHelpers
    alias Shoestring.Trajectory.Goal
    alias Shoestring.{Repo, Worktrees}

    @concurrent %{global_limit: 2, provider_account_limit: 2, goal_limit: 2, account_units: 2}

    setup do
      configure_node!()
      :ok
    end

    defp step(c) do
      opts =
        c.opts
        |> Keyword.drop([:fanout_enabled, :reservation_policy])
        |> Keyword.merge(plan_fanout: [enabled: true], reservation_policy: @concurrent)

      PlanFanoutDriver.step(c.goal.id, opts)
    end

    defp status!(c) do
      {:ok, status} = PlanExecutor.status(c.goal.id, c.opts)
      status
    end

    defp classes(status),
      do:
        Enum.map(
          status.children,
          &%{task: &1.plan_task_id, attempt: &1.attempt, class: &1.stop_class}
        )

    test "demo: DAG fan-out, partial failure, restart, replacement, dependent unlock and overlap refusal" do
      transcript = []
      c = fixture(worktrees_dir: Shoestring.State.path(:worktrees))

      # 1-2. An approved DAG fans its two independent tasks into separate stores.
      assert {:ok, %{disposition: :dispatched, dispatched: [north, south]}} = step(c)
      {:ok, north_tree} = Worktrees.get(north.run_id)
      {:ok, south_tree} = Worktrees.get(south.run_id)
      assert north_tree.path != south_tree.path and north_tree.repo_path != south_tree.repo_path

      transcript =
        transcript ++
          [
            %{
              step: 2,
              dispatched: ["north", "south"],
              separate_private_stores: true,
              mode: "fanout_v1"
            }
          ]

      # 3. One child fails while the other completes.
      barrier_opts!(%{
        dispatch_id!(south.run_id) => Fake.Scenario.mid_run_crash(now: PlanExecutorHelpers.now())
      })

      left = start_worker!(north.run_id)
      right = start_worker!(south.run_id)
      finish!(left)
      finish!(right)
      observe!(c.opts, north.run_id, "run.completed")
      observe!(c.opts, south.run_id, "run.failed")

      transcript =
        transcript ++ [%{step: 3, accepted: status!(c).accepted, children: classes(status!(c))}]

      # 4. Restart: accepted work, the failure and ownership are reconstructed.
      restart!()
      after_restart = status!(c)
      assert after_restart.accepted == ["north"]
      assert Reservations.outstanding() == []

      transcript =
        transcript ++
          [
            %{
              step: 4,
              accepted: after_restart.accepted,
              children: classes(after_restart),
              outstanding_reservations: 0
            }
          ]

      # 5. The failed child is replaced through admission; join stays locked.
      assert {:ok, %{dispatched: [replacement]}} = step(c)
      assert {replacement.plan_task_id, replacement.attempt} == {"south", 2}
      refute Enum.any?(status!(c).children, &(&1.plan_task_id == "join"))

      transcript =
        transcript ++ [%{step: 5, replaced: "south", attempt: 2, join_dispatched: false}]

      finish!(start_worker!(replacement.run_id))
      observe!(c.opts, replacement.run_id, "run.completed")

      # 6. Only after both acceptance gates does the dependent unlock.
      assert ["north", "south"] = status!(c).accepted
      assert {:ok, %{dispatched: [join]}} = step(c)
      assert join.plan_task_id == "join"
      finish!(start_worker!(join.run_id))
      observe!(c.opts, join.run_id, "run.completed")
      assert {:ok, %{disposition: :completed}} = step(c)
      done = status!(c)
      assert done.completed? and done.accepted == ["join", "north", "south"]
      assert %Goal{status: "completed"} = Repo.get!(Goal, c.goal.id)

      transcript =
        transcript ++
          [
            %{
              step: 6,
              join_unlocked_after: ["north", "south"],
              completed: true,
              goal_row: "completed",
              total_attempts: done.total_attempts
            }
          ]

      # 7. Overlapping declared scopes refuse fan-out and run sequentially.
      overlap =
        fixture(
          independent_only: true,
          worktrees_dir: Shoestring.State.path(:worktrees),
          transform_tasks: fn tasks ->
            Enum.map(tasks, &put_in(&1, ["hints", "files"], ["lib/north.ex"]))
          end
        )

      assert {:ok, %{disposition: :blocked, reason: :independence_unverified}} =
               PlanFanout.dispatch_ready(overlap.goal.id, overlap.opts)

      assert {:ok, %{plan_task_id: "north"}} =
               PlanFanoutDriver.step(
                 overlap.goal.id,
                 overlap.opts
                 |> Keyword.drop([:fanout_enabled, :reservation_policy])
                 |> Keyword.merge(
                   plan_fanout: [enabled: true],
                   reservation_policy: @concurrent,
                   admission_event_id: admission!(overlap.goal).id
                 )
               )

      {:ok, overlap_status} = PlanExecutor.status(overlap.goal.id, overlap.opts)
      assert overlap_status.dispatch_mode == :sequential and overlap_status.total_attempts == 1

      transcript =
        transcript ++
          [
            %{
              step: 7,
              fanout: "refused: independence_unverified",
              mode: "sequential",
              dispatched: 1
            }
          ]

      if path = System.get_env("SHOESTRING_FANOUT_DEMO_REPORT") do
        File.mkdir_p!(Path.dirname(path))

        File.write!(
          path,
          Jason.encode!(%{demo: "iteration-7", steps: transcript}, pretty: true) <> "\n"
        )
      end
    end
  else
    @tag timeout: 240_000
    test "iteration-7 demo on an isolated node with live supervised Fake Elves" do
      root = Path.join(File.cwd!(), ".shoestring/fanout-demo-#{Ecto.UUID.generate()}")
      report = System.get_env("SHOESTRING_FANOUT_DEMO_REPORT")

      {output, status} =
        System.cmd(
          "python3",
          [
            "-c",
            "import subprocess,sys; r=subprocess.run(['mix','test',sys.argv[1],'--seed','0'],stdin=subprocess.DEVNULL,timeout=200); sys.exit(r.returncode)",
            "test/shoestring/cobbler/plan_fanout_demo_test.exs"
          ],
          env:
            [{"SHOESTRING_FANOUT_DEMO_CHILD", "1"}, {"SHOESTRING_TEST_STATE_DIR", root}] ++
              if(report, do: [{"SHOESTRING_FANOUT_DEMO_REPORT", Path.expand(report)}], else: []),
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "1 test, 0 failures"
    end
  end
end
