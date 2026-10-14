defmodule Shoestring.Cobbler.PlanFanoutIntegrationTest do
  use ExUnit.Case, async: false

  if System.get_env("SHOESTRING_FANOUT_CHILD") == "1" do
    import Ecto.Query
    import Shoestring.Test.PlanFanoutHelpers
    alias Shoestring.Cobbler.{PlanExecutor, PlanFanout, ReservationRecovery, Reservations}
    alias Shoestring.Harness.{DispatchRecord, DispatchWorker, Fake, Projector, RunRecord}
    alias Shoestring.Test.{FanoutBarrierFake, PlanExecutorHelpers, PlanHandoffClock}
    alias Shoestring.{Elves, Repo, Worktrees}

    setup do
      config = Application.fetch_env!(:shoestring, Repo)

      Application.put_env(
        :shoestring,
        Repo,
        Keyword.put(config, :pool, DBConnection.ConnectionPool)
      )

      Application.put_env(:shoestring, :dispatch_effect, Shoestring.Harness.Dispatch.ElfEffect)
      Application.put_env(:shoestring, :dispatch_clock, PlanHandoffClock)
      restart!()
      :ok
    end

    test "intent restart, two live Fake children, independent acceptance and dependency admission" do
      c = fixture(worktrees_dir: Shoestring.State.path(:worktrees))
      assert {:ok, result} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
      [north, south] = result.dispatched
      restart!()

      assert {:ok, %{active_children: children, total_attempts: 2}} =
               PlanExecutor.status(c.goal.id, c.opts)

      assert length(children) == 2

      assert {:ok, %{dispatched: []}} =
               PlanFanout.dispatch_ready(
                 c.goal.id,
                 Keyword.put(c.opts, :admission_fun, fn _, _, _, _ ->
                   flunk("restart duplicated admission")
                 end)
               )

      Application.put_env(:shoestring, :elf_dispatch_opts,
        adapter: FanoutBarrierFake,
        clock: PlanHandoffClock,
        command: ["sleep", "30"],
        adapter_opts: %{
          scenario: Fake.Scenario.normal_completion(now: PlanExecutorHelpers.now()),
          barrier_parent: self()
        },
        runner_opts: [kill_grace_ms: 100, reap_timeout_ms: 1000]
      )

      left = start_worker!(north.run_id)
      right = start_worker!(south.run_id)
      assert left != right
      # The stream barrier follows committed run.running events; update the
      # durable read model before asserting its live-state view.
      assert {:ok, _} = Projector.project(c.goal.id, clock: PlanHandoffClock)
      assert Repo.get!(RunRecord, north.run_id).status == "running"
      assert Repo.get!(RunRecord, south.run_id).status == "running"
      assert length(Reservations.outstanding()) == 2
      {:ok, north_tree} = Worktrees.get(north.run_id)
      {:ok, south_tree} = Worktrees.get(south.run_id)
      assert north_tree.path != south_tree.path and north_tree.repo_path != south_tree.repo_path

      finish!(right)

      assert {:ok, %{reason: :fanout_coordinator_required}} =
               PlanExecutor.resume(c.goal.id, c.opts)

      assert {:ok, %{accepted: ["south"], active_run_id: id}} =
               PlanExecutor.status(c.goal.id, c.opts)

      assert id == north.run_id
      assert Elves.whereis(north.run_id) == left
      assert Repo.get!(RunRecord, north.run_id).status == "running"
      assert Enum.map(Reservations.outstanding(), & &1.run_id) == [north.run_id]
      assert {:ok, %{dispatched: []}} = PlanFanout.dispatch_ready(c.goal.id, c.opts)

      finish!(left)

      assert {:ok, %{reason: :fanout_coordinator_required}} =
               PlanExecutor.resume(c.goal.id, c.opts)

      assert Reservations.outstanding() == []
      assert {:ok, result} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
      assert [%{plan_task_id: "join"} = join] = result.dispatched
      assert {:ok, join_tree} = Worktrees.get(join.run_id)
      assert join_tree.base_commit == c.base
      join_pid = start_worker!(join.run_id)
      finish!(join_pid)

      assert {:ok, %{reason: :fanout_coordinator_required}} =
               PlanExecutor.resume(c.goal.id, c.opts)

      restart!()

      assert {:ok,
              %{accepted: ["join", "north", "south"], active_children: [], completed?: false}} =
               PlanExecutor.status(c.goal.id, c.opts)

      assert Reservations.outstanding() == []
      assert Repo.aggregate(from(r in RunRecord, where: r.goal_id == ^c.goal.id), :count) == 3
      assert git!(c.source, ["status", "--porcelain"]) == ""
      assert git!(c.source, ["rev-parse", "HEAD"]) |> String.trim() == c.base
      # Global acceptance and worker activation are deliberately still fenced.
      assert {:ok, %{disposition: :blocked, reason: :fanout_coordinator_required}} =
               PlanExecutor.advance(c.goal.id, c.opts)
    end

    test "competing coordinators converge and explicit cancellation of one unstarted child preserves the other" do
      c = fixture(worktrees_dir: Shoestring.State.path(:worktrees))
      admissions = Map.new(~w(north south), &{&1, admission!(c.goal).id})

      opts =
        Keyword.put(c.opts, :admission_fun, fn _, _, task, _ ->
          {:ok, Map.fetch!(admissions, task["id"])}
        end)

      supervisor = start_supervised!(Task.Supervisor)
      parent = self()

      callers =
        for _ <- 1..4 do
          Task.Supervisor.async_nolink(supervisor, fn ->
            send(parent, {:ready, self()})

            receive do
              :coordinate -> PlanFanout.dispatch_ready(c.goal.id, opts)
            after
              10_000 -> flunk("coordinator barrier timed out")
            end
          end)
        end

      for caller <- callers do
        pid = caller.pid
        assert_receive {:ready, ^pid}, 10_000
      end

      Enum.each(callers, &send(&1.pid, :coordinate))
      results = Enum.map(callers, &Task.await(&1, 30_000))
      assert Enum.all?(results, &match?({:ok, _}, &1)), inspect(results)
      assert Repo.aggregate(from(r in RunRecord, where: r.goal_id == ^c.goal.id), :count) == 2

      assert {:ok, %{active_children: children, total_attempts: 2}} =
               PlanExecutor.status(c.goal.id, c.opts)

      assert Enum.map(children, & &1.plan_task_id) == ["north", "south"]
      [first, second] = Reservations.outstanding() |> Enum.filter(&(&1.goal_id == c.goal.id))
      assert {:ok, %{settlement: %{kind: "released"}}} = cancel_unstarted(first)
      assert Enum.map(Reservations.outstanding(), & &1.id) == [second.id]
      assert Repo.get!(RunRecord, second.run_id).status == "requested"
      assert Repo.get!(RunRecord, first.run_id).status == "cancelled"
      assert {:ok, %{settlement: %{kind: "released"}}} = cancel_unstarted(second)
      assert Reservations.outstanding() == []
      assert {:ok, _} = Worktrees.get(first.run_id)
      assert {:ok, _} = Worktrees.get(second.run_id)
    end

    defp cancel_unstarted(owner) do
      result =
        Repo.transaction(
          fn ->
            ReservationRecovery.cancel_unstarted(owner, Ecto.UUID.generate(),
              now: PlanExecutorHelpers.now(),
              repo: Repo,
              elf_lookup: &Elves.whereis/1
            )
          end,
          mode: :immediate
        )

      assert {:ok, _} = Projector.project(owner.goal_id, clock: PlanHandoffClock)
      result
    end

    defp start_worker!(run_id) do
      dispatch = Repo.get_by!(DispatchRecord, run_id: run_id)
      assert :ok = DispatchWorker.perform(Repo.get!(Oban.Job, dispatch.job_id))
      id = dispatch.dispatch_id
      assert_receive {:fanout_stream_ready, pid, ^id}, 15_000
      assert Elves.whereis(run_id) == pid
      pid
    end

    defp finish!(pid) do
      ref = Process.monitor(pid)
      send(pid, :release_stream)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 15_000
    end

    defp restart! do
      pid = Process.whereis(Shoestring.Supervisor)
      ref = Process.monitor(pid)
      assert :ok = Application.stop(:shoestring)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 15_000
      assert {:ok, _} = Application.ensure_all_started(:shoestring)
    end
  else
    @tag timeout: 180_000
    test "internal fan-out lifecycle on an isolated node with normal pooled SQLite connections" do
      root = Path.join(File.cwd!(), ".shoestring/fanout-#{Ecto.UUID.generate()}")

      {output, status} =
        System.cmd(
          "python3",
          [
            "-c",
            "import subprocess,sys; r=subprocess.run(['mix','test',sys.argv[1],'--seed','0'],stdin=subprocess.DEVNULL,timeout=150); sys.exit(r.returncode)",
            "test/shoestring/cobbler/plan_fanout_integration_test.exs"
          ],
          env: [{"SHOESTRING_FANOUT_CHILD", "1"}, {"SHOESTRING_TEST_STATE_DIR", root}],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "2 tests, 0 failures"
    end
  end
end
