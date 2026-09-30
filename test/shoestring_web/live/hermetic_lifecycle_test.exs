defmodule ShoestringWeb.HermeticLifecycleTest do
  use ExUnit.Case, async: false

  if System.get_env("SHOESTRING_LIFECYCLE_CHILD") == "1" do
    import Ecto.Query
    import Phoenix.ConnTest
    import Phoenix.LiveViewTest

    alias Shoestring.Harness.{CheckpointRecord, ExecutionLeaseRecord, RunRecord}
    alias Shoestring.Repo
    alias Shoestring.Test.HermeticLifecycleClock

    @endpoint ShoestringWeb.Endpoint
    @recovery_processes [
      Shoestring.Harness.Dispatch.Reconciler,
      Shoestring.Cobbler.WakeupReconciler,
      Shoestring.Cobbler.HandoffReconciler
    ]

    setup do
      start_supervised!({HermeticLifecycleClock, now: DateTime.utc_now()})
      Application.put_env(:shoestring, :dispatch_clock, HermeticLifecycleClock)
      # Real commits on a disposable child-node database and the ordinary
      # connection pool. No sandbox owner or transaction can masquerade as
      # durability across application stop. This configuration is confined
      # to this child VM; the parent suite retains its sandbox.
      config = Application.fetch_env!(:shoestring, Repo)

      Application.put_env(
        :shoestring,
        Repo,
        Keyword.put(config, :pool, DBConnection.ConnectionPool)
      )

      for key <- [:dispatch_reconciler, :wakeup_reconciler, :handoff_reconciler] do
        Application.put_env(:shoestring, key, true)
      end

      Application.put_env(:shoestring, :dispatch_effect, Shoestring.Harness.Dispatch.ElfEffect)

      restart_application!()
      :ok
    end

    test "provider quota refusal survives application restart and one freshly admitted continuation completes" do
      owner = self()
      healthy = capacity(20.0, "00000000-0000-4000-8000-f00000000611")

      Application.put_env(:shoestring, :run_submission_observe, fn scoping ->
        send(owner, {:capacity_observed, :submission, scoping})
        {:ok, healthy}
      end)

      quota =
        Shoestring.Harness.Fake.Scenario.sudden_quota_refusal(now: HermeticLifecycleClock.now())

      quota = %{quota | capacity: capacity(100.0, "00000000-0000-4000-8000-f00000000612")}

      Application.put_env(:shoestring, :elf_dispatch_opts,
        scenario: quota,
        clock: HermeticLifecycleClock
      )

      {:ok, view, _} = live(build_conn(), "/runs/new")
      view |> element("#btn-use-fixture") |> render_click()

      {:error, {:live_redirect, %{to: "/runs/" <> run_id}}} =
        view
        |> form("#manual-run-form", %{
          "run" => %{
            "prompt" => "Complete the hermetic acceptance contract",
            "scenario" => "success"
          }
        })
        |> render_submit()

      dispatch = Repo.get_by!(Shoestring.Harness.DispatchRecord, run_id: run_id)
      job = Repo.one!(from j in Oban.Job, where: j.args["dispatch_id"] == ^dispatch.dispatch_id)
      assert :ok = Shoestring.Harness.DispatchWorker.perform(job)

      await_owned_elf(run_id)
      run = Repo.get!(RunRecord, run_id)
      assert run.status == "failed"

      assert_receive {:capacity_observed, :submission,
                      %{provider_id: "fake", scope: "subscription"}}

      assert_group_reaped!(run_id)

      checkpoint =
        Repo.get!(CheckpointRecord, Shoestring.Elves.TerminalCheckpoint.checkpoint_id(run.id))

      assert checkpoint.id == Shoestring.Elves.TerminalCheckpoint.checkpoint_id(run.id)
      assert checkpoint.stop_reason == "run.failed:rate_limit_exceeded"

      reactive =
        Repo.get!(
          CheckpointRecord,
          Shoestring.Elves.TerminalCheckpoint.reactive_checkpoint_id(run.id)
        )

      assert reactive.run_id == run.id

      assert Enum.any?(
               checkpoint.evidence["items"],
               &String.contains?(&1, "quota_refused/rate_limit_exceeded")
             )

      assert Enum.any?(checkpoint.acceptance_contract["criteria"], fn criterion ->
               String.contains?(criterion, "task #{run.task_id}") and
                 String.contains?(criterion, "Complete the hermetic acceptance contract")
             end)

      lease = Repo.get_by!(ExecutionLeaseRecord, run_id: run.id)
      assert lease.status == "checkpoint_required"
      assert lease.extensions["cobbler.lease:scope"] == "subscription"
      wake = Repo.get_by!(Shoestring.Cobbler.WakeupRecord, run_id: run.id)
      assert wake.reason == "lease_decline_recheck"
      wake_job = Repo.one!(from j in Oban.Job, where: j.args["wakeup_id"] == ^wake.id)

      old_recovery = Map.new(@recovery_processes, &{&1, Process.whereis(&1)})
      {:ok, worktree} = Shoestring.Worktrees.get(run.id)
      restart_application!()
      assert Repo.get!(RunRecord, run.id) == run
      assert Repo.get!(CheckpointRecord, checkpoint.id) == checkpoint
      assert Repo.get!(CheckpointRecord, reactive.id) == reactive
      assert Repo.get!(ExecutionLeaseRecord, lease.id) == lease
      assert {:ok, ^worktree} = Shoestring.Worktrees.get(run.id)
      assert Repo.get!(Shoestring.Cobbler.WakeupRecord, wake.id) == wake

      for {name, old_pid} <- old_recovery do
        assert is_pid(old_pid)
        refute Process.whereis(name) == old_pid
      end

      HermeticLifecycleClock.advance(61)

      Application.put_env(:shoestring, :wakeup_observe, fn scoping ->
        send(owner, {:capacity_observed, :wakeup, scoping})
        {:ok, capacity(20.0, "00000000-0000-4000-8000-f00000000613")}
      end)

      completion =
        Shoestring.Harness.Fake.Scenario.normal_completion(now: HermeticLifecycleClock.now())

      completion = %{
        completion
        | capacity: capacity(20.0, "00000000-0000-4000-8000-f00000000614")
      }

      Application.put_env(:shoestring, :elf_dispatch_opts,
        scenario: completion,
        clock: HermeticLifecycleClock
      )

      assert :ok = Shoestring.Cobbler.WakeupWorker.perform(wake_job)
      assert_receive {:capacity_observed, :wakeup, %{provider_id: "fake", scope: "subscription"}}
      assert Repo.get!(RunRecord, run.id) == run
      assert Repo.get!(Shoestring.Cobbler.WakeupRecord, wake.id).status == "woken"

      assert {:ok, %{outcome: :replayed, wakeup: replayed, job: nil}} =
               Shoestring.Cobbler.Wakeups.schedule(run.goal_id,
                 run_id: run.id,
                 command_id: wake.command_id,
                 wake_at: wake.wake_at,
                 reason: wake.reason,
                 clock: HermeticLifecycleClock
               )

      assert replayed.id == wake.id

      assert Repo.aggregate(
               from(w in Shoestring.Cobbler.WakeupRecord, where: w.goal_id == ^run.goal_id),
               :count
             ) == 1

      continued =
        Repo.one!(from r in RunRecord, where: r.goal_id == ^run.goal_id and r.id != ^run.id)

      assert continued.task_id == run.task_id
      assert continued.workspace_ref == run.workspace_ref
      assert continued.prompt == run.prompt
      assert continued.continuation["checkpoint_id"] == checkpoint.id
      assert continued.continuation["next_action"] == checkpoint.next_action

      continuation_dispatch =
        Repo.get_by!(Shoestring.Harness.DispatchRecord, run_id: continued.id)

      continuation_job =
        Repo.one!(
          from j in Oban.Job, where: j.args["dispatch_id"] == ^continuation_dispatch.dispatch_id
        )

      assert :ok = Shoestring.Harness.DispatchWorker.perform(continuation_job)
      await_owned_elf(continued.id)
      assert_group_reaped!(continued.id)
      assert Repo.get!(RunRecord, continued.id).status == "completed"
      assert Repo.get!(RunRecord, run.id).status == "failed"

      assert Repo.get_by!(ExecutionLeaseRecord, run_id: continued.id).status ==
               "checkpoint_required"

      assert Repo.get!(
               CheckpointRecord,
               Shoestring.Elves.TerminalCheckpoint.checkpoint_id(continued.id)
             ).stop_reason == "run.completed"

      assert :ok = Shoestring.Cobbler.WakeupWorker.perform(wake_job)
      assert :ok = Shoestring.Harness.DispatchWorker.perform(continuation_job)
      refute_receive {:capacity_observed, :wakeup, _}
      assert Repo.aggregate(from(r in RunRecord, where: r.goal_id == ^run.goal_id), :count) == 2

      {:ok, goal_view, _} = live(build_conn(), "/cobbler/goals/#{run.goal_id}")

      assert has_element?(goal_view, "#cobbler-goal-status[data-status='completed']")
      refute has_element?(goal_view, "#cobbler-lease-status[data-status='active']")
    end

    defp capacity(used, id) do
      snapshot =
        Shoestring.Harness.Fake.Scenario.healthy_snapshot(id, HermeticLifecycleClock.now())

      %{
        snapshot
        | windows: [
            %{kind: "five_hour", state: :observed, used_percent: used, reset_at: nil},
            %{kind: "weekly", state: :observed, used_percent: 20.0, reset_at: nil}
          ]
      }
    end

    defp await_owned_elf(run_id) do
      on_exit(fn ->
        case Shoestring.Elves.whereis(run_id) do
          nil ->
            :ok

          pid ->
            ref = Process.monitor(pid)
            Shoestring.Elves.Elf.cancel(pid)
            assert_receive {:DOWN, ^ref, :process, ^pid, _}, 15_000
        end
      end)

      case Shoestring.Elves.whereis(run_id) do
        nil ->
          :ok

        pid ->
          ref = Process.monitor(pid)
          assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 15_000
      end
    end

    defp assert_group_reaped!(run_id) do
      running =
        Repo.one!(
          from e in Shoestring.Trajectory.TrajectoryEvent,
            where: e.run_id == ^run_id and e.type == "run.running"
        )

      "pgid:" <> pgid = running.payload["process_id"]
      assert Shoestring.Test.ElvesHelpers.group_members(String.to_integer(pgid)) == []
    end

    defp restart_application! do
      children =
        Supervisor.which_children(Shoestring.Supervisor)
        |> Enum.flat_map(fn
          {id, pid, _, _} when is_pid(pid) -> [{id, pid, Process.monitor(pid)}]
          _ -> []
        end)

      root = Process.whereis(Shoestring.Supervisor)
      root_ref = Process.monitor(root)
      assert :ok = Application.stop(:shoestring)
      assert_receive {:DOWN, ^root_ref, :process, ^root, _}, 15_000

      for {_id, pid, ref} <- children do
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 15_000
      end

      assert {:ok, _apps} = Application.ensure_all_started(:shoestring)

      replacements =
        Map.new(Supervisor.which_children(Shoestring.Supervisor), fn
          {id, pid, _, _} -> {id, pid}
        end)

      for {id, old_pid, _ref} <- children do
        assert is_pid(replacements[id])
        refute replacements[id] == old_pid
      end

      for process <- @recovery_processes do
        assert %{last_result: {:ok, %{failures: []}}} = :sys.get_state(process)
      end
    end
  else
    @tag timeout: 120_000
    test "hermetic lifecycle on an isolated local node" do
      root = Path.join(File.cwd!(), ".shoestring/lifecycle-#{Ecto.UUID.generate()}")

      {output, status} =
        System.cmd(
          "python3",
          [
            "-c",
            "import subprocess, sys; " <>
              "result = subprocess.run(['mix', 'test', sys.argv[1], '--seed', '0'], " <>
              "stdin=subprocess.DEVNULL, timeout=90); sys.exit(result.returncode)",
            "test/shoestring_web/live/hermetic_lifecycle_test.exs"
          ],
          env: [
            {"SHOESTRING_LIFECYCLE_CHILD", "1"},
            {"SHOESTRING_TEST_STATE_DIR", root}
          ],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "1 test, 0 failures"
    end
  end
end
