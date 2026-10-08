defmodule Shoestring.Cobbler.PlanExecutorIntegrationTest do
  use ExUnit.Case, async: false

  if System.get_env("SHOESTRING_PLAN_EXECUTOR_CHILD") == "1" do
    import Ecto.Query
    alias Shoestring.{Cobbler, Repo, Worktrees}
    alias Shoestring.Harness.{RunRecord, DispatchRecord}

    alias Shoestring.Test.{
      CobblerHelpers,
      PlanExecutorHelpers,
      PlanFixtures,
      HermeticLifecycleClock
    }

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

      Application.put_env(:shoestring, :elf_dispatch_opts,
        clock: HermeticLifecycleClock,
        scenario: Shoestring.Harness.Fake.Scenario.normal_completion()
      )

      restart!()
      :ok
    end

    test "real workers and named gates bind both tasks and global completion across restart" do
      source = Path.join(Shoestring.State.root(), "fixture-repository")
      File.mkdir_p!(source)
      File.write!(Path.join(source, ".formatter.exs"), "[inputs: [\"*.ex\"]]\n")
      File.write!(Path.join(source, "fixture.ex"), "defmodule Fixture do\nend\n")
      git!(source, ["init"])
      git!(source, ["config", "user.name", "Fixture"])
      git!(source, ["config", "user.email", "fixture@example.invalid"])
      git!(source, ["add", ".formatter.exs", "fixture.ex"])
      git!(source, ["commit", "-m", "Fixture acceptance repository"])
      base = git!(source, ["rev-parse", "HEAD"]) |> String.trim()
      gate = %{"gate" => "mix_format_check"}

      plan =
        PlanExecutorHelpers.chain_plan(%{
          "goal" =>
            PlanFixtures.goal(%{
              "repository" => %{"base_revision" => base},
              "acceptance" => %{"gates" => [gate], "evidence" => ["Format gate passes."]}
            }),
          "tasks" => [
            PlanFixtures.task("alpha", "First fixture task", [], %{"gates" => [gate]}),
            PlanFixtures.task("beta", "Second fixture task", ["alpha"], %{"gates" => [gate]})
          ]
        })

      goal = CobblerHelpers.create_goal!()
      revision = PlanExecutorHelpers.propose_and_approve!(goal, plan)
      admission = PlanExecutorHelpers.admit!(goal)

      opts = [
        now: PlanExecutorHelpers.now(),
        clock: HermeticLifecycleClock,
        repository_path: source
      ]

      assert {:ok, _} =
               Cobbler.request_plan_execution(
                 goal.id,
                 %{
                   revision_number: revision.revision_number,
                   digest: revision.digest,
                   admission_event_id: admission.id
                 },
                 opts
               )

      assert {:ok, first} =
               Cobbler.advance_plan_execution(
                 goal.id,
                 Keyword.put(opts, :admission_event_id, admission.id)
               )

      finish_worker!(first.run_id)
      assert Repo.get!(RunRecord, first.run_id).status == "completed"

      assert {:ok, %{disposition: :accepted, commit: ^base}} =
               Cobbler.complete_plan_task_run(
                 goal.id,
                 first.run_id,
                 Keyword.put(opts, :gate_runner_opts, commit: String.duplicate("f", 40))
               )

      assert {:ok, first_worktree} = Worktrees.get(first.run_id)
      assert first_worktree.path != source
      assert {:ok, before} = Cobbler.plan_execution_status(goal.id)
      assert before.accepted == ["alpha"]
      restart!()
      assert {:ok, ^before} = Cobbler.plan_execution_status(goal.id)
      assert {:ok, ^first_worktree} = Worktrees.get(first.run_id)
      next_admission = PlanExecutorHelpers.admit!(goal)

      assert {:ok, second} =
               Cobbler.resume_plan_execution(
                 goal.id,
                 Keyword.put(opts, :admission_event_id, next_admission.id)
               )

      assert second.plan_task_id == "beta"
      finish_worker!(second.run_id)

      assert {:ok, %{disposition: :accepted, commit: ^base}} =
               Cobbler.complete_plan_task_run(goal.id, second.run_id, opts)

      assert {:ok, %{disposition: :completed, commit: ^base}} =
               Cobbler.advance_plan_execution(goal.id, opts)

      assert {:ok, %{completed?: true, accepted: ["alpha", "beta"], total_attempts: 2}} =
               Cobbler.plan_execution_status(goal.id)

      assert Repo.aggregate(from(r in RunRecord, where: r.goal_id == ^goal.id), :count) == 2
      assert git!(source, ["status", "--porcelain"]) == ""
      assert git!(source, ["rev-parse", "HEAD"]) |> String.trim() == base
    end

    defp finish_worker!(run_id) do
      dispatch = Repo.get_by!(DispatchRecord, run_id: run_id)
      job = Repo.get!(Oban.Job, dispatch.job_id)
      assert :ok = Shoestring.Harness.DispatchWorker.perform(job)

      case Shoestring.Elves.whereis(run_id) do
        nil ->
          :ok

        pid ->
          ref = Process.monitor(pid)
          assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 15_000
      end
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
    test "sequential integration on an isolated local node" do
      root = Path.join(File.cwd!(), ".shoestring/plan-executor-#{Ecto.UUID.generate()}")

      {output, status} =
        System.cmd(
          "python3",
          [
            "-c",
            "import subprocess,sys; result=subprocess.run(['mix','test',sys.argv[1],'--seed','0'],stdin=subprocess.DEVNULL,timeout=90); sys.exit(result.returncode)",
            "test/shoestring/cobbler/plan_executor_integration_test.exs"
          ],
          env: [{"SHOESTRING_PLAN_EXECUTOR_CHILD", "1"}, {"SHOESTRING_TEST_STATE_DIR", root}],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "1 test, 0 failures"
    end
  end
end
