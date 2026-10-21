defmodule Shoestring.Terminal.ElfIntegrationTest do
  use Shoestring.DataCase, async: false
  import Ecto.Query
  alias Shoestring.Test.{TerminalHelpers, ProviderCliGuard}
  alias Shoestring.Terminal.Session
  alias Shoestring.Harness.{Interactive, CheckpointRecord, RunRecord}
  alias Shoestring.Trajectory.TrajectoryEvent

  setup do
    guard = ProviderCliGuard.install!()
    fixture = TerminalHelpers.create!()
    supervisor = start_supervised!({Shoestring.Elves.Supervisor, name: nil})
    Phoenix.PubSub.subscribe(Shoestring.PubSub, Shoestring.Trajectory.topic(fixture.goal.id))

    {:ok, elf} =
      Shoestring.Elves.start_elf(fixture.request, fixture.dispatch,
        supervisor: supervisor,
        adapter: Interactive,
        adapter_opts: %{provider: "fixture"},
        process_owner: :adapter,
        command: [],
        runner_opts: [cd: fixture.worktree.path, kill_grace_ms: 200, reap_timeout_ms: 2000],
        notify: self()
      )

    run_id = fixture.dispatch.run_id

    assert_receive {:trajectory_event_committed,
                    %TrajectoryEvent{type: "run.running", run_id: ^run_id}},
                   5000

    TerminalHelpers.ready_fixture!(run_id)
    on_exit(fn -> ProviderCliGuard.assert_no_provider_cli_spawned!(guard) end)
    %{fixture: fixture, run_id: run_id, elf: elf}
  end

  test "normal TUI exit records OS status and an interrupted run/checkpoint, not task acceptance",
       ctx do
    browser = :crypto.strong_rand_bytes(32)
    {:ok, _} = Session.attach(ctx.run_id, browser)
    {:ok, _} = Session.action(ctx.run_id, browser, :takeover)
    :ok = Session.action(ctx.run_id, browser, {:input, "EXIT\r"})
    assert_receive {:elf_terminal, run_id, %{class: :interrupted}}, 5000
    assert run_id == ctx.run_id
    assert Repo.get!(RunRecord, run_id).status == "interrupted"

    exit =
      Repo.one!(
        from event in TrajectoryEvent,
          where: event.run_id == ^run_id and event.type == "terminal.session.exited"
      )

    assert exit.payload["exit_code"] == 0
    assert exit.payload["reason"] == "exited"

    assert Repo.aggregate(
             from(checkpoint in CheckpointRecord, where: checkpoint.run_id == ^run_id),
             :count
           ) == 1

    refute Repo.exists?(
             from event in TrajectoryEvent,
               where:
                 event.run_id == ^run_id and
                   event.type in ["run.completed", "cobbler.plan.task.accepted"]
           )
  end

  test "helper crash is normalized through the Elf into a durable failed checkpoint", ctx do
    pid = Session.lookup(ctx.run_id)
    state = :sys.get_state(pid)
    {:os_pid, os_pid} = Port.info(state.port, :os_pid)

    {_, 0} =
      System.cmd("python3", [
        "-c",
        "import os,signal,sys; os.kill(int(sys.argv[1]),signal.SIGKILL)",
        to_string(os_pid)
      ])

    assert_receive {:elf_terminal, run_id, %{class: :failed}}, 5000
    assert run_id == ctx.run_id
    assert Repo.get!(RunRecord, run_id).status == "failed"

    assert Repo.aggregate(
             from(checkpoint in CheckpointRecord, where: checkpoint.run_id == ^run_id),
             :count
           ) == 1

    assert Process.whereis(Shoestring.Repo) != nil
    assert Process.whereis(ShoestringWeb.Endpoint) != nil
  end
end
