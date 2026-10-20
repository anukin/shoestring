defmodule Shoestring.Cobbler.ReservationRecoveryIntegrationTest do
  use ExUnit.Case, async: false

  if System.get_env("SHOESTRING_RESERVATION_RECOVERY_CHILD") == "1" do
    alias Shoestring.{Repo, Trajectory}

    alias Shoestring.Cobbler.{
      ReservationControl,
      ReservationOperationRecord,
      ReservationSettlementRecord,
      ReservationWorker,
      Reservations
    }

    alias Shoestring.Harness.{Dispatches, DispatchRecord, RunRecord}
    alias Shoestring.Test.{PlanHandoffClock, ReservationHelpers}

    test "repository-only CLI queues recovery, restart repairs delivery and cancellation races safely with effect claim" do
      config = Application.fetch_env!(:shoestring, Repo)

      Application.put_env(
        :shoestring,
        Repo,
        Keyword.merge(config, pool: DBConnection.ConnectionPool, pool_size: 5)
      )

      restart!()
      shell = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(shell) end)
      c = ReservationHelpers.fixture()
      id = Ecto.UUID.generate()

      Mix.Tasks.Shoestring.Reservations.run([
        "cancel-unstarted",
        c.owner.id,
        "--command-id",
        id,
        "--by",
        "human:operator"
      ])

      assert_receive {:mix_shell, :info, [json]}
      queued = Jason.decode!(json)
      job = Repo.get!(Oban.Job, queued["job_id"])
      assert Repo.get!(RunRecord, c.run.id).status == "requested"
      assert Repo.aggregate(ReservationSettlementRecord, :count) == 0
      Repo.update!(Ecto.Changeset.change(job, state: "discarded"))
      restart!()
      assert {:ok, %{repaired_count: 1, failures: []}} = ReservationControl.repair()
      assert {:ok, %{repaired_count: 0, failures: []}} = ReservationControl.repair()

      supervisor = start_supervised!({Task.Supervisor, name: Shoestring.Test.RecoveryRaceTasks})
      parent = self()

      calls = [
        fn -> ReservationControl.perform(id, clock: PlanHandoffClock) end,
        fn -> Dispatches.prepare_for_effect(c.run.dispatch_id, clock: PlanHandoffClock) end
      ]

      tasks =
        Enum.map(calls, fn call ->
          Task.Supervisor.async_nolink(supervisor, fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> call.()
            after
              5_000 -> flunk("recovery race barrier timed out")
            end
          end)
        end)

      pids =
        for _ <- tasks do
          assert_receive {:ready, pid}, 5_000
          pid
        end

      Enum.each(pids, &send(&1, :go))
      [recovery, effect] = Enum.map(tasks, &Task.await(&1, 15_000))

      case {recovery, effect} do
        {{:ok, %{"disposition" => "released"}}, {:ok, {:skip, :cancelled}}} ->
          assert Repo.get!(RunRecord, c.run.id).status == "cancelled"
          assert Repo.get!(DispatchRecord, c.run.dispatch_id).status == "cancelled"
          assert Reservations.outstanding() == []

        {{:ok, %{"disposition" => "retained", "reason" => "dispatch_effect_uncertain"}},
         {:ok, {:execute, _, _}}} ->
          assert Repo.get!(DispatchRecord, c.run.dispatch_id).status == "effect_started"
          assert length(Reservations.outstanding()) == 1
          assert Repo.aggregate(ReservationSettlementRecord, :count) == 0

        other ->
          flunk("unsafe recovery/effect outcome: #{inspect(other)}")
      end

      assert Repo.get!(ReservationOperationRecord, id).status == "completed"
      assert {:ok, events} = Trajectory.replay(c.goal.id)
      assert Enum.count(events, &(&1.type == "cobbler.reservation.operation.completed")) == 1
      assert :ok = ReservationWorker.perform(%Oban.Job{args: %{"operation_id" => id}})
      restart!()
      assert {:ok, replay} = ReservationControl.perform(id)
      assert replay == elem(recovery, 1)
    end

    defp restart! do
      pid = Process.whereis(Shoestring.Supervisor)
      ref = Process.monitor(pid)
      assert :ok = Application.stop(:shoestring)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 15_000
      assert {:ok, _} = Application.ensure_all_started(:shoestring)
    end
  else
    @tag timeout: 120_000
    test "operator recovery on an isolated node with independent connections" do
      root = Path.join(File.cwd!(), ".shoestring/reservation-recovery-#{Ecto.UUID.generate()}")

      {output, status} =
        System.cmd(
          "python3",
          [
            "-c",
            "import subprocess,sys; result=subprocess.run(['mix','test',sys.argv[1],'--seed','0'],stdin=subprocess.DEVNULL,timeout=90); sys.exit(result.returncode)",
            "test/shoestring/cobbler/reservation_recovery_integration_test.exs"
          ],
          env: [
            {"SHOESTRING_RESERVATION_RECOVERY_CHILD", "1"},
            {"SHOESTRING_TEST_STATE_DIR", root}
          ],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "1 test, 0 failures"
    end
  end
end
