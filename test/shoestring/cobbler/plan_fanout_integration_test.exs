defmodule Shoestring.Cobbler.PlanFanoutIntegrationTest do
  use ExUnit.Case, async: false

  if System.get_env("SHOESTRING_FANOUT_CHILD") == "1" do
    import Ecto.Query
    import Shoestring.Test.PlanFanoutHelpers

    alias Shoestring.Cobbler.{
      PlanChildInboxReconciler,
      PlanChildMessage,
      PlanChildWorker,
      PlanExecutor,
      PlanFanout,
      ReservationRecovery,
      Reservations
    }

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

      assert :ok =
               Phoenix.PubSub.subscribe(Shoestring.PubSub, Shoestring.Trajectory.topic(c.goal.id))

      finish!(right)
      observe_terminal!(c, south.run_id)

      assert_receive {:trajectory_event_committed,
                      %{type: "cobbler.plan.task.accepted", id: event_id, payload: payload}},
                     5_000

      assert Repo.get!(Shoestring.Trajectory.TrajectoryEvent, event_id).payload == payload

      assert {:ok, %{"root_run_id" => root}} =
               Shoestring.Cobbler.PlanFinalScope.decode(payload["scope_json"])

      assert root == south.run_id

      assert :ok =
               Phoenix.PubSub.unsubscribe(
                 Shoestring.PubSub,
                 Shoestring.Trajectory.topic(c.goal.id)
               )

      assert {:ok, %{accepted: ["south"], active_run_id: id}} =
               PlanExecutor.status(c.goal.id, c.opts)

      assert id == north.run_id
      assert Elves.whereis(north.run_id) == left
      assert Repo.get!(RunRecord, north.run_id).status == "running"
      assert Enum.map(Reservations.outstanding(), & &1.run_id) == [north.run_id]
      assert {:ok, %{dispatched: []}} = PlanFanout.dispatch_ready(c.goal.id, c.opts)

      finish!(left)
      observe_terminal!(c, north.run_id)

      assert Reservations.outstanding() == []
      assert {:ok, result} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
      assert [%{plan_task_id: "join"} = join] = result.dispatched
      assert {:ok, join_tree} = Worktrees.get(join.run_id)
      assert join_tree.base_commit == c.base
      join_pid = start_worker!(join.run_id)
      finish!(join_pid)
      observe_terminal!(c, join.run_id)

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

    test "startup repairs discarded child delivery and accepts it without restarting its sibling" do
      c = fixture(independent_only: true, worktrees_dir: Shoestring.State.path(:worktrees))
      assert {:ok, result} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
      [north, south] = result.dispatched

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

      pid = start_worker!(south.run_id)
      finish!(pid)

      event =
        Repo.get_by!(Shoestring.Trajectory.TrajectoryEvent,
          type: "run.completed",
          run_id: south.run_id
        )

      row = Repo.get!(PlanChildMessage, event.id)

      Repo.get!(Oban.Job, row.job_id)
      |> Ecto.Changeset.change(state: "discarded")
      |> Repo.update!()

      previous = Application.get_env(:shoestring, :plan_child_inbox_reconciler)
      on_exit(fn -> Application.put_env(:shoestring, :plan_child_inbox_reconciler, previous) end)
      Application.put_env(:shoestring, :plan_child_inbox_reconciler, true)
      restart!()
      _ = :sys.get_state(PlanChildInboxReconciler)
      repaired = Repo.get!(PlanChildMessage, event.id)
      assert repaired.job_id != row.job_id
      assert Repo.get!(Oban.Job, row.job_id).state == "discarded"
      observe_terminal!(c, south.run_id)

      assert {:ok, %{accepted: ["south"], active_run_id: id, total_attempts: 2}} =
               PlanExecutor.status(c.goal.id, c.opts)

      assert id == north.run_id and Repo.get!(RunRecord, north.run_id).status == "requested"
      assert Enum.map(Reservations.outstanding(), & &1.run_id) == [north.run_id]
      assert Repo.aggregate(from(r in RunRecord, where: r.goal_id == ^c.goal.id), :count) == 2
      assert git!(c.source, ["status", "--porcelain"]) == ""
      # Targeted cancellation also delivers a durable child message and must
      # retain the already accepted sibling.
      [owner] = Enum.filter(Reservations.outstanding(), &(&1.goal_id == c.goal.id))
      assert {:ok, %{settlement: %{kind: "released"}}} = cancel_unstarted(owner)

      cancelled =
        Repo.get_by!(Shoestring.Trajectory.TrajectoryEvent,
          type: "run.cancelled",
          run_id: north.run_id
        )

      message = Repo.get!(PlanChildMessage, cancelled.id)
      assert message.message_kind == "cancelled"
      assert :ok = PlanChildWorker.perform(Repo.get!(Oban.Job, message.job_id))
      assert Repo.get!(PlanChildMessage, cancelled.id).status == "observed"
      assert {:ok, %{accepted: ["south"]}} = PlanExecutor.status(c.goal.id, c.opts)
    end

    test "a terminal scope conflict preserves a still-running sibling and its later acceptance" do
      c = fixture(independent_only: true, worktrees_dir: Shoestring.State.path(:worktrees))
      assert {:ok, result} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
      [north, south] = result.dispatched

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
      {:ok, tree} = Worktrees.get(north.run_id)
      File.write!(Path.join(tree.path, "lib/unplanned.ex"), "defmodule Unplanned do\nend\n")
      git!(tree.path, ["add", "."])
      git!(tree.path, ["commit", "-m", "Retained conflicting child output"])
      finish!(left)

      assert {:ok, %{disposition: :scope_blocked}} =
               PlanExecutor.complete_task_run(c.goal.id, north.run_id, c.opts)

      assert Elves.whereis(south.run_id) == right
      assert Enum.map(Reservations.outstanding(), & &1.run_id) == [south.run_id]

      assert {:error, :fanout_scope_resolution_required} =
               PlanFanout.dispatch_ready(c.goal.id, c.opts)

      finish!(right)

      assert {:ok, %{disposition: :accepted}} =
               PlanExecutor.complete_task_run(c.goal.id, south.run_id, c.opts)

      restart!()

      assert {:ok,
              %{accepted: ["south"], needs_user?: true, scope_blockers: [_], active_children: []}} =
               PlanExecutor.status(c.goal.id, c.opts)

      assert Reservations.outstanding() == []
      assert File.exists?(Path.join(tree.path, "lib/unplanned.ex"))
      assert Repo.aggregate(from(r in RunRecord, where: r.goal_id == ^c.goal.id), :count) == 2
      assert git!(c.source, ["status", "--porcelain"]) == ""
      assert git!(c.source, ["rev-parse", "HEAD"]) |> String.trim() == c.base
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

    defp observe_terminal!(c, run_id) do
      event =
        Repo.get_by!(Shoestring.Trajectory.TrajectoryEvent, type: "run.completed", run_id: run_id)

      row = Repo.get!(PlanChildMessage, event.id)
      Application.put_env(:shoestring, :plan_child_inbox_opts, c.opts)
      assert :ok = PlanChildWorker.perform(Repo.get!(Oban.Job, row.job_id))
      assert Repo.get!(PlanChildMessage, event.id).status == "observed"
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
      assert output =~ "4 tests, 0 failures"
    end
  end
end
