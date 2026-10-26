defmodule Shoestring.DispatchIntegrationTest do
  @moduledoc """
  A coordinator's dispatch end to end (iteration 14): grant, dispatch,
  admission, a sandboxed Claude Elf in a private worktree, the checks,
  acceptance, `runs show` and taking the commit. Everything is real except the
  `claude` executable, which is `test/support/fake_claude_cli.py`: it makes the
  change, commits it and prints Claude's stream-json frames. No provider CLI,
  no network.
  """
  use ExUnit.Case, async: false

  if System.get_env("SHOESTRING_DISPATCH_E2E_CHILD") == "1" do
    import Ecto.Query

    alias Shoestring.{Advice, Dispatches, Grants, ModelCatalog, Repo, Worktrees}
    alias Shoestring.Cobbler.PlanExecutionWorker
    alias Shoestring.Harness.{ClaudeHeadless, DispatchRecord, RunRecord}
    alias Shoestring.Trajectory.TrajectoryEvent

    @brief """
    IMPLEMENT - make add() return the sum of its arguments
    Stay out of: test/
    Contract: test/test_calc.py passes.
    """

    setup do
      config = Application.fetch_env!(:shoestring, Repo)

      Application.put_env(
        :shoestring,
        Repo,
        Keyword.merge(config, pool: DBConnection.ConnectionPool, pool_size: 5)
      )

      Application.put_env(:shoestring, :dispatch_effect, Shoestring.Harness.Dispatch.ElfEffect)

      fake = Path.join(Shoestring.State.root(), "bin/claude")
      File.mkdir_p!(Path.dirname(fake))
      File.cp!(Path.expand("support/fake_claude_cli.py", Path.dirname(__DIR__)), fake)
      File.chmod!(fake, 0o755)
      log = Path.join(Shoestring.State.root(), "fake-claude.jsonl")
      System.put_env("FAKE_CLAUDE_LOG", log)

      # The run launches exactly as a dispatched Claude run does, sandbox
      # settings included; only the executable is the stand-in.
      Application.put_env(:shoestring, :elf_dispatch_opts,
        adapter_opts: %{live: true, executable: fake}
      )

      restart!()
      %{log: log}
    end

    test "a coordinator's dispatch runs a Claude Elf to a verified commit the user can take",
         ctx do
      source = Path.join(Shoestring.State.root(), "calc")
      File.mkdir_p!(Path.join(source, "test"))
      File.write!(Path.join(source, "calc.py"), "def add(a, b):\n    raise NotImplementedError\n")
      File.write!(Path.join(source, "test/__init__.py"), "")

      File.write!(Path.join(source, "test/test_calc.py"), """
      import unittest

      from calc import add


      class AddTest(unittest.TestCase):
          def test_add(self):
              self.assertEqual(add(2, 3), 5)
      """)

      git!(source, ["init", "-q", "-b", "main"])
      git!(source, ["add", "."])

      git!(source, [
        "-c",
        "user.name=T",
        "-c",
        "user.email=t@example.com",
        "commit",
        "-qm",
        "base"
      ])

      base = git!(source, ["rev-parse", "HEAD"]) |> String.trim()
      {:ok, facts} = Shoestring.Cobbler.Intake.repository(source)

      {:ok, _} = ModelCatalog.add("claude", "opus")

      {:ok, grant} =
        Grants.create(
          %{
            session_id: "s1",
            repository_root: facts.root,
            models: ["claude:opus"],
            purposes: ["implement"],
            max_dispatches: 1,
            max_parallel: 1,
            max_total_seconds: 3_600,
            max_dispatch_seconds: 1_800,
            unread_usage: 0
          },
          "human:operator"
        )

      # Shoestring has read Claude's usage: plenty left in both windows.
      claude_reading!()

      {:ok, dispatch, :recorded} =
        Dispatches.create(%{
          session_id: "s1",
          request_id: "r1",
          purpose: "implement",
          provider: "claude",
          model: "opus",
          effort: "high",
          title: "Make add return the sum of its arguments",
          brief: @brief,
          repository: source,
          files: ["calc.py"],
          stay_out: ["test/"]
        })

      assert Dispatches.state(dispatch) == "queued"

      job =
        Repo.one!(from j in Oban.Job, where: j.worker == "Shoestring.Cobbler.PlanExecutionWorker")

      # Admitted and dispatched: one Claude run in a private worktree.
      assert {:snooze, 5} = PlanExecutionWorker.perform(job)
      run = Repo.one!(from r in RunRecord, where: r.goal_id == ^dispatch.goal_id)
      assert run.provider_id == ClaudeHeadless.identity().adapter_id
      assert run.extensions["shoestring.agent:binding"]["dispatch_id"] == dispatch.id
      assert Dispatches.state(dispatch) == "running"

      finish_worker!(run.id)
      assert Repo.get!(RunRecord, run.id).status == "completed"

      # The checks pass at the worker's commit; the dispatch is complete.
      assert :ok = PlanExecutionWorker.perform(job)
      assert Dispatches.state(dispatch) == "completed"

      accepted =
        Repo.one!(
          from e in TrajectoryEvent,
            where: e.goal_id == ^dispatch.goal_id and e.type == "cobbler.plan.task.accepted"
        )

      commit = accepted.payload["commit"]
      assert commit != base
      assert {:ok, worktree} = Worktrees.get(run.id)
      assert git!(worktree.path, ["show", "#{commit}:calc.py"]) =~ "return a + b"
      assert git!(worktree.path, ["rev-parse", "#{commit}^"]) |> String.trim() == base

      # The launch was the sandboxed one, with the dispatch's model, effort
      # and brief. Claude keeps the last `--effort`, so there is exactly one.
      assert [%{"argv" => argv, "cwd" => cwd}] =
               ctx.log
               |> File.read!()
               |> String.split("\n", trim: true)
               |> Enum.map(&Jason.decode!/1)

      assert Path.expand(cwd) == Path.expand(worktree.path)
      pairs = Enum.chunk_every(argv, 2, 1, :discard)
      assert ["--model", "opus"] in pairs
      assert for([flag, value] <- pairs, flag == "--effort", do: value) == ["high"]
      assert "--settings" in argv
      refute "--dangerously-skip-permissions" in argv
      prompt = List.last(argv)
      assert prompt =~ "Coordinator brief:\n" <> @brief
      assert prompt =~ "calc.py"

      # Claude's token counts were recorded for advice.
      assert Enum.any?(Advice.token_payloads(Repo), fn payload ->
               payload["run_id"] == run.id and
                 payload["extensions"]["claude-headless:input_tokens"] == 1200 and
                 payload["extensions"]["claude-headless:output_tokens"] == 340
             end)

      assert %{"runs" => 1, "estimate" => nil} =
               Advice.for_kind(%{
                 "harness" => "claude",
                 "model" => "opus",
                 "effort" => "high",
                 "purpose" => "implement",
                 "task_class" => "gates:python_unittest"
               })

      # `runs show` reports the commit and the commands that take it.
      shown = runs_show!(dispatch.id)
      assert shown["state"] == "completed"
      assert shown["result"]["commit"] == commit
      assert shown["result"]["base"] == base
      assert Enum.any?(shown["result"]["checks"], &(&1["exit_status"] == 0))
      assert Grants.get(grant.id) != nil

      # The user's checkout is untouched until they take the commit.
      assert git!(source, ["rev-parse", "HEAD"]) |> String.trim() == base
      assert git!(source, ["status", "--porcelain"]) == ""
      assert File.read!(Path.join(source, "calc.py")) =~ "NotImplementedError"

      [cd | take] = shown["result"]["take"]
      assert cd == "cd #{Shoestring.Shell.argument(facts.root)}"

      for command <- take do
        {output, status} = System.cmd("sh", ["-c", command], cd: source, stderr_to_stdout: true)
        assert status == 0, "#{command}: #{output}"
      end

      assert git!(source, ["rev-parse", "HEAD"]) |> String.trim() == commit

      assert {_, 0} =
               System.cmd("python3", ["-B", "-m", "unittest", "test/test_calc.py"],
                 cd: source,
                 stderr_to_stdout: true
               )
    end

    defp claude_reading! do
      now = DateTime.utc_now()

      {:ok, snapshot} =
        Shoestring.Harness.CapacitySnapshot.new(
          %{
            version: 2,
            snapshot_id: Ecto.UUID.generate(),
            capacity_state: :observed,
            windows: [
              %{
                kind: "five_hour",
                state: :observed,
                used_percent: 20.0,
                reset_at: DateTime.add(now, 3_600)
              },
              %{
                kind: "weekly",
                state: :observed,
                used_percent: 10.0,
                reset_at: DateTime.add(now, 86_400)
              }
            ],
            freshness: %{max_age_seconds: 300},
            source: %{
              adapter_id: ClaudeHeadless.identity().adapter_id,
              provider_id: "claude",
              invocation_mode: "headless_stream_json",
              event: :explicit_read
            },
            scope: "subscription",
            confidence: :high,
            support_tier: :proactive,
            compatibility_state: :compatible,
            observed_at: now,
            reason: nil,
            extensions: %{}
          },
          now: now
        )

      {:ok, _, _} = Shoestring.Harness.Observatory.ingest(snapshot, now: now)
    end

    defp runs_show!(id) do
      context = %{
        shell: Mix.Shell.Process,
        with_repo: fn fun -> fun.(Repo) end,
        env: fn "SHOESTRING_SESSION" -> "s1" end
      }

      Shoestring.CLI.Commands.Runs.run(["show", id], context)
      assert_receive {:mix_shell, :info, [json]}
      Jason.decode!(json)
    end

    defp finish_worker!(run_id) do
      dispatch = Repo.get_by!(DispatchRecord, run_id: run_id)
      assert :ok = Shoestring.Harness.DispatchWorker.perform(Repo.get!(Oban.Job, dispatch.job_id))

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

    defp git!(dir, argv) do
      {output, status} = System.cmd("git", argv, cd: dir, stderr_to_stdout: true)
      assert status == 0, output
      output
    end
  else
    @tag timeout: 120_000
    test "a dispatch end to end on an isolated local node" do
      root = Path.join(File.cwd!(), ".shoestring/dispatch-e2e-#{Ecto.UUID.generate()}")

      {output, status} =
        System.cmd(
          "python3",
          [
            "-c",
            "import subprocess,sys; result=subprocess.run(['mix','test',sys.argv[1],'--seed','0'],stdin=subprocess.DEVNULL,timeout=90); sys.exit(result.returncode)",
            "test/shoestring/dispatch_integration_test.exs"
          ],
          env: [{"SHOESTRING_DISPATCH_E2E_CHILD", "1"}, {"SHOESTRING_TEST_STATE_DIR", root}],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "1 test, 0 failures"
    end
  end
end
