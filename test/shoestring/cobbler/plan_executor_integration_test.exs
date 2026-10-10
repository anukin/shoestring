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

    test "an approved amendment retains acceptance through real workers, gates and restart" do
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

      amended =
        Map.update!(plan, "tasks", fn tasks ->
          Enum.map(tasks, fn task ->
            if task["id"] == "beta",
              do: Map.put(task, "outcome", "An amended remaining fixture task."),
              else: task
          end)
        end)

      plan_opts = [now: PlanExecutorHelpers.now(), publish_fun: fn _ -> :ok end]

      assert {:ok, %{revision: amendment}} =
               Cobbler.propose_plan(
                 goal.id,
                 PlanFixtures.propose_attrs(
                   plan: amended,
                   parent_revision_number: 1,
                   proposal_id: "fixture-amendment"
                 ),
                 plan_opts
               )

      amended_attrs = %{
        revision_number: amendment.revision_number,
        digest: amendment.digest,
        admission_event_id: admission.id
      }

      assert {:error, {:authority_mismatch, _}} =
               Cobbler.request_plan_execution(goal.id, amended_attrs, opts)

      assert {:ok, _} =
               Cobbler.approve_plan(
                 goal.id,
                 PlanFixtures.approve_attrs(amendment.revision_number, amendment.digest,
                   decision_id: "fixture-amendment-approval"
                 ),
                 plan_opts
               )

      assert {:ok, _} = Cobbler.request_plan_execution(goal.id, amended_attrs, opts)
      assert {:ok, carried} = Cobbler.plan_execution_status(goal.id)
      assert carried.execution.revision_number == 2
      assert carried.accepted == before.accepted
      assert carried.attempts == before.attempts
      assert carried.total_gate_duration_ms == before.total_gate_duration_ms
      restart!()
      assert {:ok, ^carried} = Cobbler.plan_execution_status(goal.id)
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

    test "CLI planner, edit and approval drive code acceptance through quota continuation and restart" do
      source = Path.join(Shoestring.State.root(), "cli-fixture-repository")
      File.mkdir_p!(Path.join(source, "lib"))
      File.mkdir_p!(Path.join(source, "test"))

      File.write!(
        Path.join(source, "mix.exs"),
        "defmodule Fixture.MixProject do\n  use Mix.Project\n  def project, do: [app: :fixture, version: \"0.1.0\"]\nend\n"
      )

      File.write!(Path.join(source, ".gitignore"), "/_build/\n")

      File.write!(
        Path.join(source, ".formatter.exs"),
        "[inputs: [\"mix.exs\", \"{lib,test}/**/*.{ex,exs}\"]]\n"
      )

      File.write!(Path.join(source, "lib/fixture.ex"), "defmodule Fixture do\nend\n")
      File.write!(Path.join(source, "test/test_helper.exs"), "ExUnit.start()\n")

      File.write!(
        Path.join(source, "test/alpha_test.exs"),
        "defmodule Fixture.AlphaTest do\n  use ExUnit.Case\n  test \"greeting\", do: assert(Fixture.greeting() == \"hello\")\nend\n"
      )

      File.write!(
        Path.join(source, "test/beta_test.exs"),
        "defmodule Fixture.BetaTest do\n  use ExUnit.Case\n  test \"composed message\", do: assert(Fixture.message() == \"hello fixture\")\nend\n"
      )

      git!(source, ["init"])
      git!(source, ["config", "user.name", "Fixture"])
      git!(source, ["config", "user.email", "fixture@example.invalid"])
      git!(source, ["add", "."])
      git!(source, ["commit", "-m", "CLI fixture acceptance repository"])
      base = git!(source, ["rev-parse", "HEAD"]) |> String.trim()
      goal = CobblerHelpers.create_goal!()

      plan =
        PlanExecutorHelpers.chain_plan(%{
          "goal" =>
            PlanFixtures.goal(%{
              "repository" => %{"base_revision" => base},
              "acceptance" => %{
                "gates" => [%{"gate" => "mix_test"}],
                "evidence" => ["Both fixture tests pass."]
              }
            }),
          "tasks" => [
            PlanFixtures.task("alpha", "Implement greeting", [], %{
              "gates" => [%{"gate" => "mix_test", "test_paths" => ["test/alpha_test.exs"]}]
            }),
            PlanFixtures.task("beta", "Compose greeting", [], %{
              "gates" => [%{"gate" => "mix_test", "test_paths" => ["test/beta_test.exs"]}]
            })
          ]
        })

      previous_shell = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(previous_shell) end)
      planner_config = Shoestring.Test.PlannerFixtures.config([{:ok, Jason.encode!(plan), 12}])
      Application.put_env(:shoestring, :planner, planner_config)
      planner_now = DateTime.utc_now()

      assert {:ok, :persisted, _} =
               Shoestring.Harness.Observatory.ingest(
                 Shoestring.Test.PlannerFixtures.snapshot(planner_now),
                 now: planner_now
               )

      goal_file = Path.join(Shoestring.State.root(), "demo-goal.json")
      File.write!(goal_file, Jason.encode!(plan["goal"]))

      assert cli_plan!([
               "request",
               goal.id,
               "--file",
               goal_file,
               "--request-key",
               "demo-initial",
               "--by",
               "human:fixture"
             ])["planner"]["attempts"] == 0

      generated = cli_plan!(["generate", goal.id, "--request-key", "demo-initial"])
      assert generated["planner"]["state"] == "ready"
      assert_receive {:planner_input, _}
      refute Shoestring.Cobbler.Plans.authority(goal.id)

      adopted =
        cli_plan!([
          "adopt",
          goal.id,
          "--request-key",
          "demo-initial",
          "--digest",
          generated["planner"]["candidate_digest"],
          "--by",
          "human:fixture"
        ])

      exported = cli_plan!(["export", goal.id, "--revision", "1"])
      assert Enum.find(exported["tasks"], &(&1["id"] == "beta"))["depends_on"] == []

      edited =
        Map.update!(exported, "tasks", fn tasks ->
          Enum.map(tasks, fn task ->
            if task["id"] == "beta", do: Map.put(task, "depends_on", ["alpha"]), else: task
          end)
        end)

      plan_file = Path.join(Shoestring.State.root(), "demo-edited-plan.json")
      File.write!(plan_file, Jason.encode!(edited))

      reviewed =
        cli_plan!([
          "edit",
          goal.id,
          "--revision",
          "1",
          "--digest",
          adopted["revision"]["digest"],
          "--file",
          plan_file,
          "--request-id",
          "demo-edit",
          "--by",
          "human:fixture"
        ])

      assert reviewed["revision"]["status"] == "proposed"
      digest = reviewed["revision"]["digest"]

      assert {:error, :no_approved_authority} =
               Cobbler.request_plan_execution(goal.id, %{revision_number: 2, digest: digest},
                 now: PlanExecutorHelpers.now()
               )

      approved =
        cli_plan!([
          "approve",
          goal.id,
          "--revision",
          "2",
          "--digest",
          digest,
          "--request-id",
          "demo-approve",
          "--by",
          "human:fixture"
        ])

      assert approved["revision"]["status"] == "approved"

      assert Shoestring.Cobbler.Plans.get_revision(goal.id, 1).digest ==
               adopted["revision"]["digest"]

      revision = %{revision_number: 2, digest: digest}
      assert cli_plan!(["show", goal.id])["plan"] == edited
      assert Repo.aggregate(from(r in RunRecord, where: r.goal_id == ^goal.id), :count) == 0

      assert {:ok, _} =
               Shoestring.AgentProfiles.save_settings(Shoestring.AgentProfiles.settings(), %{
                 "codex_models" => "fixture-model"
               })

      attrs = Shoestring.ConfigurationFixtures.agent_attrs()

      roles =
        Enum.map(attrs["roles"], fn role ->
          if role["provider"] == "codex", do: Map.put(role, "model", "fixture-model"), else: role
        end)

      assert {:ok, agent} = Shoestring.AgentProfiles.create(Map.put(attrs, "roles", roles))
      assert {:ok, profile} = Shoestring.AgentProfiles.snapshot_by_id(agent.id)

      Mix.Tasks.Shoestring.Execution.run([
        "start",
        goal.id,
        "--revision",
        to_string(revision.revision_number),
        "--digest",
        revision.digest,
        "--repo",
        source,
        "--agent",
        agent.id,
        "--agent-revision",
        "1",
        "--agent-digest",
        profile["digest"],
        "--role",
        "Worker",
        "--by",
        "human:fixture"
      ])

      assert_receive {:mix_shell, :info, [json]}
      result = Jason.decode!(json)
      job = Repo.get!(Oban.Job, result["job_id"])
      assert Repo.aggregate(from(r in RunRecord, where: r.goal_id == ^goal.id), :count) == 0
      now = HermeticLifecycleClock.now()

      healthy =
        Shoestring.ConfigurationFixtures.capacity_fixture(%{
          observed_at: now,
          scope: "subscription",
          windows: [
            %{
              kind: "five_hour",
              state: :observed,
              used_percent: 25.0,
              reset_at: DateTime.add(now, 3600)
            },
            %{
              kind: "weekly",
              state: :observed,
              used_percent: 10.0,
              reset_at: DateTime.add(now, 86400)
            }
          ]
        })

      Application.put_env(:shoestring, :elf_dispatch_opts,
        adapter: Shoestring.Test.FixturePlanFake,
        process_owner: :runner,
        command: ["cat"],
        clock: HermeticLifecycleClock,
        adapter_opts: %{
          scenario: %{
            Shoestring.Harness.Fake.Scenario.sudden_quota_refusal(now: now)
            | capacity: %{
                healthy
                | snapshot_id: Ecto.UUID.generate(),
                  windows: Enum.map(healthy.windows, &%{&1 | used_percent: 100.0})
              }
          }
        }
      )

      assert {:snooze, 5} = Shoestring.Cobbler.PlanExecutionWorker.perform(job)
      first = Repo.one!(from r in RunRecord, where: r.goal_id == ^goal.id)
      finish_worker!(first.id)
      assert Repo.get!(RunRecord, first.id).status == "failed"

      checkpoint =
        Repo.get!(
          Shoestring.Harness.CheckpointRecord,
          Shoestring.Elves.TerminalCheckpoint.checkpoint_id(first.id)
        )

      assert checkpoint.run_id == first.id
      assert checkpoint.stop_reason == "run.failed:rate_limit_exceeded"
      restart!()
      assert {:snooze, 5} = Shoestring.Cobbler.PlanExecutionWorker.perform(job)
      assert Repo.aggregate(from(r in RunRecord, where: r.goal_id == ^goal.id), :count) == 1
      now = HermeticLifecycleClock.advance(61)

      fresh = %{
        healthy
        | snapshot_id: Ecto.UUID.generate(),
          observed_at: now,
          expires_at: DateTime.add(now, 300)
      }

      assert {:ok, _, _} = Shoestring.Harness.Observatory.ingest(fresh, now: now)

      Application.put_env(
        :shoestring,
        :wakeup_observe,
        {Shoestring.Cobbler.WakeupObserve, :observe, []}
      )

      Application.put_env(:shoestring, :elf_dispatch_opts,
        adapter: Shoestring.Test.FixturePlanFake,
        process_owner: :runner,
        command: ["cat"],
        clock: HermeticLifecycleClock,
        adapter_opts: %{
          scenario: %{
            Shoestring.Harness.Fake.Scenario.normal_completion(now: now)
            | capacity: fresh
          }
        }
      )

      wake = Repo.get_by!(Shoestring.Cobbler.WakeupRecord, run_id: first.id)
      wake_job = Repo.one!(from j in Oban.Job, where: j.args["wakeup_id"] == ^wake.id)
      assert :ok = Shoestring.Cobbler.WakeupWorker.perform(wake_job)

      continued =
        Repo.one!(from r in RunRecord, where: r.goal_id == ^goal.id and r.id != ^first.id)

      assert continued.task_id == first.task_id
      assert continued.workspace_ref == first.workspace_ref

      assert continued.extensions ==
               Map.put(
                 first.extensions,
                 "wakeup:resume_prior_session_id",
                 Repo.get!(RunRecord, first.id).provider_session_id
               )

      assert continued.continuation["checkpoint_id"] == checkpoint.id
      finish_worker!(continued.id)
      assert :ok = Shoestring.Cobbler.WakeupWorker.perform(wake_job)
      assert {:ok, %{accepted: [], total_attempts: 1}} = Cobbler.plan_execution_status(goal.id)
      assert {:snooze, 5} = Shoestring.Cobbler.PlanExecutionWorker.perform(job)

      second =
        Repo.one!(
          from r in RunRecord,
            where: r.goal_id == ^goal.id and r.id not in ^[first.id, continued.id]
        )

      assert {:ok, accepted_before_restart} = Cobbler.plan_execution_status(goal.id)
      assert accepted_before_restart.accepted == ["alpha"]
      planner_before_restart = Shoestring.Cobbler.Planner.get(goal.id)
      assert planner_before_restart.attempts == 1
      restart!()
      assert {:ok, ^accepted_before_restart} = Cobbler.plan_execution_status(goal.id)

      assert Shoestring.Cobbler.Planner.get(goal.id).result_digest ==
               planner_before_restart.result_digest

      assert cli_plan!(["planner", goal.id])["attempts"] == 1
      refute_receive {:planner_input, _}
      finish_worker!(second.id)
      assert :ok = Shoestring.Cobbler.PlanExecutionWorker.perform(job)

      assert {:ok, %{completed?: true, accepted: ["alpha", "beta"], total_attempts: 2}} =
               Cobbler.plan_execution_status(goal.id)

      assert {:ok, second_worktree} = Worktrees.get(second.id)
      assert File.read!(Path.join(second_worktree.path, "lib/fixture.ex")) =~ "def message"
      assert git!(source, ["rev-parse", "HEAD"]) |> String.trim() == base
      assert File.read!(Path.join(source, "lib/fixture.ex")) == "defmodule Fixture do\nend\n"
      assert git!(source, ["status", "--porcelain"]) == ""

      assert first.extensions["shoestring.agent:binding"] ==
               second.extensions["shoestring.agent:binding"]

      invalid_goal = CobblerHelpers.create_goal!()

      cyclic =
        Map.update!(plan, "tasks", fn tasks ->
          Enum.map(tasks, fn task ->
            Map.put(task, "depends_on", if(task["id"] == "alpha", do: ["beta"], else: ["alpha"]))
          end)
        end)

      Application.put_env(
        :shoestring,
        :planner,
        Shoestring.Test.PlannerFixtures.config([{:ok, Jason.encode!(cyclic), 12}])
      )

      planner_now = DateTime.utc_now()

      assert {:ok, :persisted, _} =
               Shoestring.Harness.Observatory.ingest(
                 Shoestring.Test.PlannerFixtures.snapshot(planner_now),
                 now: planner_now
               )

      cli_plan!([
        "request",
        invalid_goal.id,
        "--file",
        goal_file,
        "--request-key",
        "demo-invalid",
        "--by",
        "human:fixture"
      ])

      rejected = cli_plan!(["generate", invalid_goal.id, "--request-key", "demo-invalid"])
      assert rejected["planner"]["state"] == "schema_failed"
      assert rejected["planner"]["candidate"] == nil
      assert rejected["planner"]["errors"] != []
      assert cli_plan!(["planner", invalid_goal.id])["state"] == "schema_failed"
      assert Shoestring.Cobbler.Plans.list_revisions(invalid_goal.id) == []

      assert Repo.aggregate(from(r in RunRecord, where: r.goal_id == ^invalid_goal.id), :count) ==
               0

      assert_receive {:planner_input, _}
      refute_receive {:planner_input, _}

      assert Repo.aggregate(from(r in RunRecord, where: r.goal_id == ^goal.id), :count) == 3

      assert Repo.aggregate(
               from(e in Shoestring.Trajectory.TrajectoryEvent,
                 where: e.goal_id == ^goal.id and e.type == "cobbler.plan.task.accepted"
               ),
               :count
             ) == 2

      assert {:ok, %{outcome: :completed, job_id: nil}} =
               Shoestring.Cobbler.ExecutionControl.continue(
                 goal.id,
                 result["execution"]["execution_id"]
               )
    end

    defp cli_plan!(args) do
      Mix.Tasks.Shoestring.Plans.run(args)
      assert_receive {:mix_shell, :info, [json]}
      Jason.decode!(json)
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
      assert output =~ "2 tests, 0 failures"
    end
  end
end
