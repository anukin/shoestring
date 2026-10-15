defmodule Shoestring.Cobbler.PlanFanoutEvalTest do
  @moduledoc """
  Iteration-7 required evaluations not already covered by a named scenario.
  Live cases run on an isolated node with pooled SQLite, real supervised Fake
  Elves and real process groups; see the iteration evidence for the full map.
  """
  use ExUnit.Case, async: false

  if System.get_env("SHOESTRING_FANOUT_EVAL_CHILD") == "1" do
    import Ecto.Query
    import Shoestring.Test.PlanFanoutHelpers
    import Shoestring.Test.FanoutNodeHelpers

    alias Shoestring.Cobbler.{PlanCancellation, PlanExecutor, PlanFanout, Reservations}
    alias Shoestring.Elves.PortRunner
    alias Shoestring.Harness.{Fake, RunRecord}
    alias Shoestring.Test.PlanExecutorHelpers
    alias Shoestring.{Elves, Repo, Worktrees}

    setup do
      configure_node!()
      :ok
    end

    test "restart while two children run recovers both once without duplicate work" do
      c = fixture(independent_only: true, worktrees_dir: Shoestring.State.path(:worktrees))
      assert {:ok, %{dispatched: [north, south]}} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
      working = working_scenario()

      barrier_opts!(%{
        dispatch_id!(north.run_id) => working,
        dispatch_id!(south.run_id) => working
      })

      release!(start_worker!(north.run_id))
      release!(start_worker!(south.run_id))
      pgids = Enum.map([north, south], &recorded_pgid!(&1.run_id))
      assert Enum.all?(pgids, &PortRunner.alive_id?/1)

      restart!()

      # A restart never interrupts useful work: both owned groups keep running
      # and stay owned; nothing is re-admitted or re-spawned.
      assert Enum.all?(pgids, &PortRunner.alive_id?/1)
      assert Elves.whereis(north.run_id) == nil and Elves.whereis(south.run_id) == nil
      assert {:ok, status} = PlanExecutor.status(c.goal.id, c.opts)

      assert Enum.sort(Enum.map(status.children, & &1.run_id)) ==
               Enum.sort([north.run_id, south.run_id])

      assert status.total_attempts == 2
      assert Enum.all?(status.children, &(&1.stop_class == :running))
      assert length(Reservations.outstanding()) == 2

      assert {:ok, %{dispatched: []}} =
               PlanFanout.dispatch_ready(
                 c.goal.id,
                 Keyword.put(c.opts, :admission_fun, fn _, _, _, _ ->
                   flunk("duplicate admission")
                 end)
               )

      assert Repo.aggregate(from(r in RunRecord, where: r.goal_id == ^c.goal.id), :count) == 2

      # The recovered service still controls both groups through their record.
      assert {:ok, request} =
               PlanCancellation.request(c.goal.id, %{
                 execution_id: c.execution.execution_id,
                 reason: "Stop recovered work.",
                 command_id: Ecto.UUID.generate(),
                 requested_by: "human:operator"
               })

      assert {:ok, %{outcomes: outcomes}} =
               PlanCancellation.perform(c.goal.id, request.cancellation_id, c.opts)

      assert Enum.map(outcomes, & &1["outcome"]) == ["cancelled", "cancelled"]
      refute Enum.any?(pgids, &PortRunner.alive_id?/1)
      assert Reservations.outstanding() == []
    end

    test "one passing and one crashing sibling retain the passing evidence and both branches" do
      c = fixture(independent_only: true, worktrees_dir: Shoestring.State.path(:worktrees))
      assert {:ok, %{dispatched: [north, south]}} = PlanFanout.dispatch_ready(c.goal.id, c.opts)

      barrier_opts!(%{
        dispatch_id!(south.run_id) => Fake.Scenario.mid_run_crash(now: PlanExecutorHelpers.now())
      })

      left = start_worker!(north.run_id)
      right = start_worker!(south.run_id)
      finish!(left)
      observe!(c.opts, north.run_id, "run.completed")
      finish!(right)
      observe!(c.opts, south.run_id, "run.failed")

      assert {:ok, status} = PlanExecutor.status(c.goal.id, c.opts)
      assert status.accepted == ["north"]
      [accepted] = status.accepted_evidence

      assert %{stop_class: :adapter_failure} =
               Enum.find(status.children, &(&1.run_id == south.run_id))

      assert {:ok, _} = Worktrees.get(north.run_id)
      assert {:ok, _} = Worktrees.get(south.run_id)
      restart!()

      assert {:ok, %{accepted: ["north"], accepted_evidence: [^accepted]}} =
               PlanExecutor.status(c.goal.id, c.opts)
    end

    test "goal cancellation boundedly stops every live child" do
      c = fixture(independent_only: true, worktrees_dir: Shoestring.State.path(:worktrees))
      assert {:ok, %{dispatched: [north, south]}} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
      working = working_scenario()

      barrier_opts!(%{
        dispatch_id!(north.run_id) => working,
        dispatch_id!(south.run_id) => working
      })

      pids = Enum.map([north, south], &release!(start_worker!(&1.run_id)))
      pgids = Enum.map([north, south], &recorded_pgid!(&1.run_id))
      refs = Enum.map(pids, &Process.monitor/1)

      assert {:ok, request} =
               PlanCancellation.request(c.goal.id, %{
                 execution_id: c.execution.execution_id,
                 reason: "Stop the goal.",
                 command_id: Ecto.UUID.generate(),
                 requested_by: "human:operator"
               })

      started = System.monotonic_time(:millisecond)

      assert {:ok, %{outcomes: outcomes}} =
               PlanCancellation.perform(c.goal.id, request.cancellation_id, c.opts)

      elapsed = System.monotonic_time(:millisecond) - started
      assert Enum.map(outcomes, & &1["outcome"]) == ["cancelled", "cancelled"]
      for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _, _}, 15_000)
      refute Enum.any?(pgids, &PortRunner.alive_id?/1)
      assert Reservations.outstanding() == []
      # Bounded: TERM, a 100 ms configured grace in the Elf, then KILL.
      assert elapsed < 30_000
      assert {:error, :execution_cancelled} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
    end
  else
    use Shoestring.DataCase, async: false
    import Shoestring.Test.PlanFanoutHelpers
    alias Shoestring.Cobbler.{PlanFanout, ReservationRecord}

    test "provider cap: three ready tasks under a provider limit of one acquire one slot" do
      c =
        fixture(
          reconciliation_opts: [group_probe: fn _ -> :absent end],
          transform_tasks: fn tasks -> Enum.map(tasks, &Map.put(&1, "depends_on", [])) end
        )

      opts =
        Keyword.put(c.opts, :reservation_policy, %{
          global_limit: 3,
          provider_account_limit: 1,
          goal_limit: 3,
          account_units: 3
        })

      assert {:ok, result} = PlanFanout.dispatch_ready(c.goal.id, opts)
      assert [%{plan_task_id: "north"}] = result.dispatched

      assert Enum.map(result.blocked, &{&1.plan_task_id, &1.reason}) == [
               {"south", {:reservation_blocked, :provider_account_limit}},
               {"join", {:reservation_blocked, :provider_account_limit}}
             ]

      assert Repo.aggregate(ReservationRecord, :count) == 1
    end

    @tag timeout: 240_000
    test "required evaluations on an isolated node with real process groups" do
      root = Path.join(File.cwd!(), ".shoestring/fanout-eval-#{Ecto.UUID.generate()}")

      {output, status} =
        System.cmd(
          "python3",
          [
            "-c",
            "import subprocess,sys; r=subprocess.run(['mix','test',sys.argv[1],'--seed','0'],stdin=subprocess.DEVNULL,timeout=200); sys.exit(r.returncode)",
            "test/shoestring/cobbler/plan_fanout_eval_test.exs"
          ],
          env: [{"SHOESTRING_FANOUT_EVAL_CHILD", "1"}, {"SHOESTRING_TEST_STATE_DIR", root}],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "3 tests, 0 failures"
    end
  end
end
