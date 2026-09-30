defmodule ShoestringWeb.HermeticLifecycleTest do
  use ExUnit.Case, async: false

  if System.get_env("SHOESTRING_LIFECYCLE_CHILD") == "1" do
    import Ecto.Query
    import Phoenix.ConnTest
    import Phoenix.LiveViewTest

    alias Shoestring.Harness.{CheckpointRecord, ExecutionLeaseRecord, RunRecord}
    alias Shoestring.Repo

    @endpoint ShoestringWeb.Endpoint
    @recovery_processes [
      Shoestring.Harness.Dispatch.Reconciler,
      Shoestring.Cobbler.WakeupReconciler,
      Shoestring.Cobbler.HandoffReconciler
    ]

    setup do
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

      restart_application!()
      :ok
    end

    test "Fake submission reaches a producer-created terminal checkpoint" do
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

      await_owned_elf(run_id)
      run = Repo.get!(RunRecord, run_id)
      assert run.status == "completed"
      assert_group_reaped!(run_id)
      checkpoint = Repo.get_by!(CheckpointRecord, run_id: run.id)
      assert checkpoint.id == Shoestring.Elves.TerminalCheckpoint.checkpoint_id(run.id)
      assert checkpoint.stop_reason == "run.completed"

      assert Enum.any?(checkpoint.acceptance_contract["criteria"], fn criterion ->
               String.contains?(criterion, "task #{run.task_id}") and
                 String.contains?(criterion, "Complete the hermetic acceptance contract")
             end)

      lease = Repo.get_by!(ExecutionLeaseRecord, run_id: run.id)
      refute lease.status in ["granted", "active", "renewal_due", "renewed"]

      old_recovery = Map.new(@recovery_processes, &{&1, Process.whereis(&1)})
      {:ok, worktree} = Shoestring.Worktrees.get(run.id)
      restart_application!()
      assert Repo.get!(RunRecord, run.id) == run
      assert Repo.get!(CheckpointRecord, checkpoint.id) == checkpoint
      assert Repo.get!(ExecutionLeaseRecord, lease.id) == lease
      assert {:ok, ^worktree} = Shoestring.Worktrees.get(run.id)

      for {name, old_pid} <- old_recovery do
        assert is_pid(old_pid)
        refute Process.whereis(name) == old_pid
      end

      {:ok, goal_view, _} = live(build_conn(), "/cobbler/goals/#{run.goal_id}")
      assert has_element?(goal_view, "#cobbler-goal-status[data-status='completed']")
      refute has_element?(goal_view, "#cobbler-lease-status[data-status='active']")
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
