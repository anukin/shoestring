defmodule Shoestring.Cobbler.ParallelDispatchNodeTest do
  @moduledoc """
  Separate single-task dispatches side by side at Settings' parallel tasks 2
  (iteration 18), on an isolated node with pooled SQLite, real application
  restarts, live supervised Fake Elves and real process groups. A restart
  keeps both in flight under their own reservations; cancelling one stops
  only its own process group and frees only its own place.
  """
  use ExUnit.Case, async: false

  if System.get_env("SHOESTRING_PARALLEL_DISPATCH_CHILD") == "1" do
    import Ecto.Query
    import Shoestring.Test.PlanFanoutHelpers
    import Shoestring.Test.FanoutNodeHelpers

    alias Shoestring.AgentProfiles
    alias Shoestring.Cobbler.{Commands, PlanCancellation, PlanExecutor, Reservations}
    alias Shoestring.Elves.PortRunner
    alias Shoestring.Harness.RunRecord
    alias Shoestring.Repo
    alias Shoestring.Trajectory.TrajectoryEvent

    setup do
      configure_node!()

      {:ok, _} =
        AgentProfiles.save_settings(AgentProfiles.settings(), %{"parallel_tasks" => "2"})

      assert Reservations.outstanding() == []
      :ok
    end

    # A one-task plan; its reservation policy is the Settings value.
    defp single do
      c =
        fixture(
          independent_only: true,
          transform_tasks: &Enum.take(&1, 1),
          worktrees_dir: Shoestring.State.path(:worktrees)
        )

      %{c | opts: Keyword.delete(c.opts, :reservation_policy)}
    end

    defp dispatch!(c) do
      assert {:ok, %{disposition: :dispatched, run_id: run_id}} =
               PlanExecutor.advance(c.goal.id, c.opts)

      run_id
    end

    defp count(c, type) do
      Repo.aggregate(
        from(e in TrajectoryEvent, where: e.goal_id == ^c.goal.id and e.type == ^type),
        :count
      )
    end

    defp runs(c),
      do: Repo.aggregate(from(r in RunRecord, where: r.goal_id == ^c.goal.id), :count)

    defp cancel!(c, reason) do
      assert {:ok, request} =
               PlanCancellation.request(c.goal.id, %{
                 execution_id: c.execution.execution_id,
                 reason: reason,
                 command_id: Ecto.UUID.generate(),
                 requested_by: "human:operator"
               })

      assert {:ok, %{outcomes: outcomes}} =
               PlanCancellation.perform(c.goal.id, request.cancellation_id, c.opts)

      outcomes
    end

    test "a restart keeps two in-flight dispatches, each with its one run and group" do
      [a, b] = [single(), single()]
      [run_a, run_b] = [dispatch!(a), dispatch!(b)]
      working = working_scenario()
      barrier_opts!(%{dispatch_id!(run_a) => working, dispatch_id!(run_b) => working})

      release!(start_worker!(run_a))
      release!(start_worker!(run_b))
      pgids = Enum.map([run_a, run_b], &recorded_pgid!/1)
      assert Enum.all?(pgids, &PortRunner.alive_id?/1)
      assert Commands.active_claim() == nil
      assert length(Reservations.outstanding()) == 2

      restart!()

      # Nothing is interrupted, re-admitted or re-spawned: each goal keeps its
      # reservation, its one run and the same live process group.
      assert Enum.all?(pgids, &PortRunner.alive_id?/1)
      assert Enum.map([run_a, run_b], &recorded_pgid!/1) == pgids
      assert length(Reservations.outstanding()) == 2

      for c <- [a, b] do
        _ =
          PlanExecutor.advance(
            c.goal.id,
            Keyword.put(c.opts, :admission_fun, fn _, _, _, _ -> flunk("duplicate admission") end)
          )

        assert runs(c) == 1
        assert count(c, "dispatch.requested") == 1
        assert count(c, "cobbler.plan.task.dispatched") == 1
      end

      assert length(Reservations.outstanding()) == 2

      # The recovered service still stops each through its own record.
      for c <- [a, b], do: assert(["cancelled"] = Enum.map(cancel!(c, "Stop."), & &1["outcome"]))
      refute Enum.any?(pgids, &PortRunner.alive_id?/1)
      assert Reservations.outstanding() == []
    end

    test "cancelling one dispatch stops only its group; the other is accepted" do
      [a, b] = [single(), single()]
      [run_a, run_b] = [dispatch!(a), dispatch!(b)]
      barrier_opts!(%{dispatch_id!(run_a) => working_scenario()})

      release!(start_worker!(run_a))
      pgid_a = recorded_pgid!(run_a)
      # b waits at the barrier with the ordinary completing scenario.
      pid_b = start_worker!(run_b)
      assert PortRunner.alive_id?(pgid_a)

      assert ["cancelled"] = Enum.map(cancel!(a, "Stop this one."), & &1["outcome"])
      refute PortRunner.alive_id?(pgid_a)

      # Only the cancelled dispatch's place is freed.
      assert Enum.map(Reservations.outstanding(), & &1.goal_id) == [b.goal.id]
      assert Shoestring.Elves.whereis(run_b) == pid_b

      finish!(pid_b)
      assert Repo.get!(RunRecord, run_b).status == "completed"
      assert {:ok, _} = PlanExecutor.resume(b.goal.id, b.opts)
      assert {:ok, %{accepted: ["north"]}} = PlanExecutor.status(b.goal.id, b.opts)
      assert {:ok, %{accepted: []}} = PlanExecutor.status(a.goal.id, a.opts)
    end
  else
    @tag timeout: 240_000
    test "separate dispatches side by side on an isolated node with real process groups" do
      root = Path.join(File.cwd!(), ".shoestring/parallel-dispatch-#{Ecto.UUID.generate()}")

      {output, status} =
        System.cmd(
          "python3",
          [
            "-c",
            "import subprocess,sys; r=subprocess.run(['mix','test',sys.argv[1],'--seed','0'],stdin=subprocess.DEVNULL,timeout=200); sys.exit(r.returncode)",
            "test/shoestring/cobbler/parallel_dispatch_node_test.exs"
          ],
          env: [{"SHOESTRING_PARALLEL_DISPATCH_CHILD", "1"}, {"SHOESTRING_TEST_STATE_DIR", root}],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "2 tests, 0 failures"
    end
  end
end
