defmodule Shoestring.Cobbler.PlanDispatchIntegrationTest do
  use ExUnit.Case, async: false

  if System.get_env("SHOESTRING_ATOMIC_DISPATCH_CHILD") == "1" do
    import Ecto.Query
    alias Shoestring.{Cobbler, Repo, Worktrees}
    alias Shoestring.Cobbler.{PlanExecutor, ReservationRecord, Reservations}
    alias Shoestring.Harness.{DispatchRecord, Fake, RunRecord}

    alias Shoestring.Test.{
      CobblerHelpers,
      PlanExecutorHelpers,
      PlanFixtures,
      HermeticLifecycleClock
    }

    alias Shoestring.Test.Fixtures.FakeHelpers
    alias Shoestring.Trajectory.TrajectoryEvent

    setup do
      start_supervised!({HermeticLifecycleClock, now: PlanExecutorHelpers.now()})
      config = Application.fetch_env!(:shoestring, Repo)

      Application.put_env(
        :shoestring,
        Repo,
        Keyword.put(config, :pool, DBConnection.ConnectionPool)
      )

      Application.put_env(:shoestring, :dispatch_effect, Shoestring.Harness.Dispatch.ElfEffect)
      Application.put_env(:shoestring, :dispatch_clock, HermeticLifecycleClock)
      Application.put_env(:shoestring, :plan_reservation_policy, %{})

      Application.put_env(:shoestring, :elf_dispatch_opts,
        clock: HermeticLifecycleClock,
        scenario: Fake.Scenario.normal_completion(now: PlanExecutorHelpers.now())
      )

      restart!()
      :ok
    end

    test "configured atomic intent survives restart, real Fake completion, settlement and the next dependency" do
      source = Path.join(Shoestring.State.root(), "atomic-source")
      File.mkdir_p!(source)
      File.write!(Path.join(source, ".formatter.exs"), "[inputs: [\"*.ex\"]]\n")
      File.write!(Path.join(source, "fixture.ex"), "defmodule Fixture do\nend\n")
      git!(source, ["init"])
      git!(source, ["config", "user.name", "Fixture"])
      git!(source, ["config", "user.email", "fixture@example.invalid"])
      git!(source, ["add", "."])
      git!(source, ["commit", "-m", "Atomic fixture base"])
      base = git!(source, ["rev-parse", "HEAD"]) |> String.trim()
      gate = %{"gate" => "mix_format_check"}

      plan =
        PlanExecutorHelpers.chain_plan(%{
          "goal" =>
            PlanFixtures.goal(%{
              "repository" => %{"base_revision" => base},
              "acceptance" => %{"gates" => [gate], "evidence" => ["Format passes."]}
            }),
          "tasks" => [
            PlanFixtures.task("alpha", "First", [], %{"gates" => [gate]}),
            PlanFixtures.task("beta", "Second", ["alpha"], %{"gates" => [gate]})
          ]
        })

      goal = CobblerHelpers.create_goal!()
      revision = PlanExecutorHelpers.propose_and_approve!(goal, plan)
      admission = admission!(goal)
      parent = self()

      publish = fn event ->
        refute Repo.in_transaction?()
        assert Repo.get!(TrajectoryEvent, event.id) == event
        assert Repo.aggregate(ReservationRecord, :count) >= 1
        assert Repo.aggregate(DispatchRecord, :count) >= 1
        send(parent, {:committed_notification, event.type})
      end

      opts = [
        now: PlanExecutorHelpers.now(),
        clock: HermeticLifecycleClock,
        repository_path: source,
        admission_event_id: admission.id,
        publish_fun: publish
      ]

      assert {:ok, _} =
               Cobbler.request_plan_execution(
                 goal.id,
                 Map.put(revision, :admission_event_id, admission.id),
                 Keyword.delete(opts, :publish_fun)
               )

      assert {:ok, first} = PlanExecutor.advance(goal.id, opts)
      assert_receive {:committed_notification, "cobbler.plan.task.dispatched"}
      assert Repo.aggregate(ReservationRecord, :count) == 1
      assert Repo.aggregate(Oban.Job, :count) == 1
      assert Repo.get!(RunRecord, first.run_id).status == "requested"
      restart!()
      assert {:ok, %{disposition: :awaiting_task}} = PlanExecutor.resume(goal.id, opts)
      finish_worker!(first.run_id)

      assert {:ok, %{disposition: :accepted, commit: ^base}} =
               PlanExecutor.complete_task_run(goal.id, first.run_id, opts)

      restart!()
      assert Enum.any?(Reservations.outstanding(), &(&1.run_id == first.run_id))
      next_admission = admission!(goal)

      assert {:ok, second} =
               PlanExecutor.resume(
                 goal.id,
                 Keyword.put(opts, :admission_event_id, next_admission.id)
               )

      assert second.plan_task_id == "beta"
      assert {:ok, first_tree} = Worktrees.get(first.run_id)
      assert {:ok, second_tree} = Worktrees.get(second.run_id)
      assert first_tree.path != second_tree.path
      finish_worker!(second.run_id)

      assert {:ok, %{disposition: :accepted}} =
               PlanExecutor.complete_task_run(goal.id, second.run_id, opts)

      assert {:ok, %{disposition: :completed}} = PlanExecutor.advance(goal.id, opts)

      assert {:ok, %{completed?: true, accepted: ["alpha", "beta"]}} =
               PlanExecutor.status(goal.id)

      assert Repo.aggregate(from(r in RunRecord, where: r.goal_id == ^goal.id), :count) == 2
      assert Repo.aggregate(ReservationRecord, :count) == 2
      assert Reservations.outstanding() == []
      assert git!(source, ["status", "--porcelain"]) == ""
      assert git!(source, ["rev-parse", "HEAD"]) |> String.trim() == base
    end

    test "a real quota wake acquires fresh ownership across restart and automatically settles at advance" do
      source = Path.join(Shoestring.State.root(), "quota-source")
      File.mkdir_p!(source)
      File.write!(Path.join(source, ".formatter.exs"), "[inputs: [\"*.ex\"]]\n")
      File.write!(Path.join(source, "fixture.ex"), "defmodule Fixture do\nend\n")
      git!(source, ["init"])
      git!(source, ["config", "user.name", "Fixture"])
      git!(source, ["config", "user.email", "fixture@example.invalid"])
      git!(source, ["add", "."])
      git!(source, ["commit", "-m", "Quota fixture base"])
      base = git!(source, ["rev-parse", "HEAD"]) |> String.trim()
      gate = %{"gate" => "mix_format_check"}

      plan =
        PlanExecutorHelpers.chain_plan(%{
          "goal" =>
            PlanFixtures.goal(%{
              "repository" => %{"base_revision" => base},
              "acceptance" => %{"gates" => [gate], "evidence" => ["Format passes."]}
            }),
          "tasks" => [
            PlanFixtures.task("alpha", "First", [], %{"gates" => [gate]}),
            PlanFixtures.task("beta", "Second", ["alpha"], %{"gates" => [gate]})
          ]
        })

      goal = CobblerHelpers.create_goal!()
      revision = PlanExecutorHelpers.propose_and_approve!(goal, plan)
      admission = admission!(goal)
      now = HermeticLifecycleClock.now()
      healthy = Fake.Scenario.normal_completion(now: now).capacity

      healthy = %{
        healthy
        | snapshot_id: Ecto.UUID.generate(),
          scope: "account:codex",
          source: %{healthy.source | provider_id: "fake"}
      }

      healthy = %{healthy | windows: healthy.windows ++ [%{hd(healthy.windows) | kind: "weekly"}]}

      quota = %{
        Fake.Scenario.sudden_quota_refusal(now: now)
        | capacity: %{healthy | windows: Enum.map(healthy.windows, &%{&1 | used_percent: 100.0})}
      }

      Application.put_env(:shoestring, :elf_dispatch_opts,
        clock: HermeticLifecycleClock,
        scenario: quota
      )

      opts = [
        now: now,
        clock: HermeticLifecycleClock,
        repository_path: source,
        admission_event_id: admission.id
      ]

      assert {:ok, _} =
               PlanExecutor.request_execution(
                 goal.id,
                 Map.put(revision, :admission_event_id, admission.id),
                 opts
               )

      assert {:ok, first} = PlanExecutor.advance(goal.id, opts)
      finish_worker!(first.run_id, "failed")
      wake = Repo.get_by!(Shoestring.Cobbler.WakeupRecord, run_id: first.run_id)
      wake_job = Repo.one!(from j in Oban.Job, where: j.args["wakeup_id"] == ^wake.id)
      restart!()
      now = HermeticLifecycleClock.advance(61)

      fresh = %{
        healthy
        | snapshot_id: Ecto.UUID.generate(),
          observed_at: now,
          expires_at: DateTime.add(now, 300)
      }

      Application.put_env(:shoestring, :wakeup_observe, fn scoping ->
        assert scoping.provider_id == "fake"
        assert scoping.scope == "account:codex"
        {:ok, fresh}
      end)

      Application.put_env(:shoestring, :elf_dispatch_opts,
        clock: HermeticLifecycleClock,
        scenario: %{Fake.Scenario.normal_completion(now: now) | capacity: fresh}
      )

      assert :ok = Shoestring.Cobbler.WakeupWorker.perform(wake_job)
      child = Repo.get!(RunRecord, wake.id)
      owner = Repo.get_by!(ReservationRecord, run_id: child.id)
      assert owner.parent_id == first.reservation_id
      assert owner.admission_event_id != admission.id
      assert owner.attempt == 1

      assert Repo.get!(Shoestring.Cobbler.ReservationSettlementRecord, first.reservation_id).kind ==
               "consumed_closed"

      assert Reservations.outstanding() == [owner]
      assert child.extensions[Reservations.key()] == owner.id

      assert child.extensions["shoestring.plan:binding"] ==
               Repo.get!(RunRecord, first.run_id).extensions["shoestring.plan:binding"]

      restart!()
      finish_worker!(child.id)
      assert :ok = Shoestring.Cobbler.WakeupWorker.perform(wake_job)
      next_admission = admission!(goal)
      opts = opts |> Keyword.put(:now, now) |> Keyword.put(:admission_event_id, next_admission.id)
      assert {:ok, second} = PlanExecutor.resume(goal.id, opts)
      assert second.plan_task_id == "beta"
      assert Enum.map(Reservations.outstanding(), & &1.run_id) == [second.run_id]
      finish_worker!(second.run_id)
      assert {:ok, %{disposition: :completed}} = PlanExecutor.resume(goal.id, opts)
      assert Reservations.outstanding() == []

      assert {:ok, %{total_attempts: 2, accepted: ["alpha", "beta"]}} =
               PlanExecutor.status(goal.id)

      assert Repo.aggregate(from(r in ReservationRecord, where: r.goal_id == ^goal.id), :count) ==
               3

      assert git!(source, ["status", "--porcelain"]) == ""
    end

    test "concurrent sequential coordinators converge on one atomic delivery" do
      goal = CobblerHelpers.create_goal!()
      revision = PlanExecutorHelpers.propose_and_approve!(goal)
      admission = admission!(goal)

      opts =
        PlanExecutorHelpers.exec_opts(
          clock: HermeticLifecycleClock,
          admission_event_id: admission.id
        )

      assert {:ok, _} =
               PlanExecutor.request_execution(
                 goal.id,
                 Map.put(revision, :admission_event_id, admission.id),
                 opts
               )

      supervisor = start_supervised!({Task.Supervisor, name: Shoestring.Test.AtomicDispatchTasks})
      parent = self()

      tasks =
        for _ <- 1..4 do
          Task.Supervisor.async_nolink(supervisor, fn ->
            send(parent, {:ready, self()})

            receive do
              :dispatch -> PlanExecutor.advance(goal.id, opts)
            after
              10_000 -> flunk("coordinator barrier timed out")
            end
          end)
        end

      pids =
        for _ <- tasks do
          assert_receive {:ready, pid}, 5_000
          pid
        end

      Enum.each(pids, &send(&1, :dispatch))
      results = Enum.map(tasks, &Task.await(&1, 15_000))
      assert Enum.all?(results, &match?({:ok, _}, &1)), inspect(results)
      assert Repo.aggregate(from(r in RunRecord, where: r.goal_id == ^goal.id), :count) == 1

      assert Repo.aggregate(from(r in ReservationRecord, where: r.goal_id == ^goal.id), :count) ==
               1

      assert Repo.aggregate(from(d in DispatchRecord, where: d.goal_id == ^goal.id), :count) == 1

      assert Repo.aggregate(
               from(e in TrajectoryEvent,
                 where: e.goal_id == ^goal.id and e.type == "cobbler.plan.task.dispatched"
               ),
               :count
             ) == 1

      assert Repo.aggregate(
               from(j in Oban.Job, where: fragment("(? ->> ?) = ?", j.args, "goal_id", ^goal.id)),
               :count
             ) == 1
    end

    defp admission!(goal) do
      now = PlanExecutorHelpers.now()
      snapshot_id = Ecto.UUID.generate()
      FakeHelpers.append_capacity_snapshot(goal, snapshot_id)

      payload =
        CobblerHelpers.admission_payload(
          provider_id: "fake",
          adapter_id: Fake.identity().adapter_id
        )
        |> Map.merge(%{
          "evaluated_at" => DateTime.to_iso8601(now),
          "observation" => %{
            "snapshot_id" => snapshot_id,
            "confidence" => "high",
            "freshness" => "fresh"
          },
          "proposed_bounds" => %{
            "response_budget" => 10,
            "tool_budget" => 25,
            "checkpoint_cadence" => 1,
            "reserves" => %{"response" => 1, "tool" => 1},
            "deadline" => DateTime.to_iso8601(DateTime.add(now, 300))
          }
        })

      CobblerHelpers.append_admission_event!(goal.id, payload)
    end

    defp finish_worker!(run_id, expected \\ "completed") do
      dispatch = Repo.get_by!(DispatchRecord, run_id: run_id)
      assert :ok = Shoestring.Harness.DispatchWorker.perform(Repo.get!(Oban.Job, dispatch.job_id))

      case Shoestring.Elves.whereis(run_id) do
        nil ->
          :ok

        pid ->
          ref = Process.monitor(pid)
          assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 15_000
      end

      assert Repo.get!(RunRecord, run_id).status == expected
    end

    defp restart! do
      pid = Process.whereis(Shoestring.Supervisor)
      ref = Process.monitor(pid)
      assert :ok = Application.stop(:shoestring)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 15_000
      assert {:ok, _} = Application.ensure_all_started(:shoestring)
    end

    defp git!(source, argv) do
      {output, status} = System.cmd("git", argv, cd: source, stderr_to_stdout: true)
      assert status == 0, output
      output
    end
  else
    @tag timeout: 120_000
    test "atomic dispatch on an isolated node with independent database connections" do
      root = Path.join(File.cwd!(), ".shoestring/atomic-dispatch-#{Ecto.UUID.generate()}")

      {output, status} =
        System.cmd(
          "python3",
          [
            "-c",
            "import subprocess,sys; result=subprocess.run(['mix','test',sys.argv[1],'--seed','0'],stdin=subprocess.DEVNULL,timeout=90); sys.exit(result.returncode)",
            "test/shoestring/cobbler/plan_dispatch_integration_test.exs"
          ],
          env: [{"SHOESTRING_ATOMIC_DISPATCH_CHILD", "1"}, {"SHOESTRING_TEST_STATE_DIR", root}],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "3 tests, 0 failures"
    end
  end
end
