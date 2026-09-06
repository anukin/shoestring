defmodule Shoestring.Elves.ElfTest do
  use Shoestring.DataCase, async: false

  import Ecto.Query

  alias Shoestring.Elves
  alias Shoestring.Elves.Elf
  alias Shoestring.Harness.Fake.Scenario
  alias Shoestring.Repo
  alias Shoestring.Test.ElfWorktreeFixture
  alias Shoestring.Test.ElvesHelpers
  alias Shoestring.Trajectory.TrajectoryEvent

  @runner_opts [kill_grace_ms: 200, reap_timeout_ms: 2_000]

  setup do
    sup = start_supervised!({Shoestring.Elves.Supervisor, name: nil})
    %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()
    {:ok, sup: sup, goal: goal, task: task}
  end

  test "launch crash: adapter refusal yields a durable classified failed run", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    request = ElvesHelpers.run_request(goal, task)
    scenario = Scenario.start_failure()

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               notify: self()
             )

    assert_receive {:elf_terminal, run_id, %{class: :failed}}, 10_000

    event = ElvesHelpers.terminal_event(goal.id, run_id)
    assert event.type == "run.failed"
    assert event.payload["error_code"] == "process_launch_failed"

    # No OS process was ever spawned for a refused launch.
    assert ElvesHelpers.count_events(goal.id, run_id, ["run.running"]) == 0
    assert ElvesHelpers.recorded_pgid(goal.id, run_id) == nil
  end

  test "immediate OS exit classifies as signal exit without an adapter verdict", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    request = ElvesHelpers.run_request(goal, task)
    scenario = ElvesHelpers.custom_scenario(:quiet_exit, [])

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["false"],
               runner_opts: @runner_opts,
               notify: self()
             )

    assert_receive {:elf_terminal, run_id, %{class: :failed}}, 10_000

    event = ElvesHelpers.terminal_event(goal.id, run_id)
    assert event.type == "run.failed"
    assert event.payload["error_category"] == "transport"
    assert String.starts_with?(event.payload["error_code"], "signal_exit_")
  end

  test "missing python3 fails the launch with a diagnosable code, not an opaque default", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    request = ElvesHelpers.run_request(goal, task)
    scenario = ElvesHelpers.custom_scenario(:no_python3, [])
    previous_path = System.get_env("PATH")

    try do
      # Absolute command path so only the python3 lookup fails, exactly like a
      # minimal host (elixir:alpine, debian-slim) without python3 installed.
      System.put_env("PATH", "/nonexistent-wpb-fixture")

      assert {:ok, _pid} =
               Elves.start_run(request, ElvesHelpers.fake_identity(),
                 supervisor: sup,
                 scenario: scenario,
                 command: ["/bin/sleep", "30"],
                 runner_opts: @runner_opts,
                 notify: self()
               )

      assert_receive {:elf_terminal, run_id, %{class: :failed}}, 10_000

      event = ElvesHelpers.terminal_event(goal.id, run_id)
      assert event.type == "run.failed"
      assert event.payload["error_code"] == "setsid_unavailable"
      assert ElvesHelpers.count_events(goal.id, run_id, ["run.running"]) == 0
    after
      if previous_path,
        do: System.put_env("PATH", previous_path),
        else: System.delete_env("PATH")
    end
  end

  test "source isolation: the Elf child edits only its real worktree", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    run_id = Ecto.UUID.generate()
    fixture = ElfWorktreeFixture.create!(run_id)
    on_exit(fn -> ElfWorktreeFixture.cleanup!(fixture) end)

    source_before = ElfWorktreeFixture.source_snapshot(fixture.source_repo)
    assert File.dir?(fixture.worktree.path)

    assert {:ok, resolved} =
             Shoestring.Worktrees.get(
               Path.join(Shoestring.State.path(:worktrees), fixture.worktree.workspace_ref)
             )

    assert resolved.path == fixture.worktree.path
    request = ElvesHelpers.run_request(goal, task, workspace_ref: fixture.worktree.workspace_ref)

    child_script = """
    from pathlib import Path
    import time

    if Path("fixture.txt").exists():
        Path("elf-source-isolation.txt").write_text("written by the Elf child\\n")
        time.sleep(1)
    """

    scenario =
      ElvesHelpers.custom_scenario(:child_worktree_edit, [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        Scenario.output_event("edited worktree", source_event_id: "evt-edit"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               run_id: run_id,
               scenario: scenario,
               command: ["python3", "-c", child_script],
               runner_opts: @runner_opts,
               event_interval_ms: 100,
               notify: self()
             )

    assert_receive {:elf_terminal, ^run_id, %{class: :completed}}, 10_000

    assert File.read!(Path.join(fixture.worktree.path, "elf-source-isolation.txt")) ==
             "written by the Elf child\n"

    assert ElfWorktreeFixture.source_snapshot(fixture.source_repo) == source_before
  end

  test "mid-run kill retains partial history and classifies the exit", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    run_id = Ecto.UUID.generate()
    fixture = ElfWorktreeFixture.create!(run_id)
    on_exit(fn -> ElfWorktreeFixture.cleanup!(fixture) end)

    source_before = ElfWorktreeFixture.source_snapshot(fixture.source_repo)
    request = ElvesHelpers.run_request(goal, task, workspace_ref: fixture.worktree.workspace_ref)

    child_script = """
    from pathlib import Path
    import time

    if Path("fixture.txt").exists():
        Path("elf-partial.txt").write_text("partial child work\\n")
        time.sleep(30)
    else:
        time.sleep(30)
    """

    scenario =
      ElvesHelpers.custom_scenario(:killed_mid_run, [
        Scenario.lifecycle_event(),
        Scenario.output_event("first", source_event_id: "evt-1"),
        Scenario.output_event("second", source_event_id: "evt-2"),
        Scenario.output_event("third", source_event_id: "evt-3")
      ])

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               run_id: run_id,
               scenario: scenario,
               command: ["python3", "-c", child_script],
               runner_opts: @runner_opts,
               event_interval_ms: 100,
               notify: self()
             )

    run_id = wait_running(goal, request.dispatch_id)

    # Wait until at least two normalized events are durable, then kill only
    # the direct child (not the group): the Elf must notice and reconcile.
    assert {:ok, _} =
             ElvesHelpers.wait_until(fn ->
               if ElvesHelpers.count_events(goal.id, run_id, ["harness.event_recorded"]) >= 2,
                 do: true
             end)

    pgid = ElvesHelpers.recorded_pgid(goal.id, run_id)
    assert is_integer(pgid)
    {_out, 0} = System.cmd("kill", ["-KILL", to_string(pgid)])
    on_exit(fn -> ElvesHelpers.cleanup_group(pgid) end)

    assert_receive {:elf_terminal, ^run_id, %{class: :failed}}, 10_000

    # Partial history survived the kill.
    assert ElvesHelpers.count_events(goal.id, run_id, ["harness.event_recorded"]) >= 2
    assert ElvesHelpers.count_events(goal.id, run_id, ["run.running"]) == 1

    # The killed child changed a real worktree, and the failed run preserved it.
    assert File.dir?(fixture.worktree.path)

    assert File.read!(Path.join(fixture.worktree.path, "elf-partial.txt")) ==
             "partial child work\n"

    assert ElfWorktreeFixture.source_snapshot(fixture.source_repo) == source_before

    event = ElvesHelpers.terminal_event(goal.id, run_id)
    assert event.type == "run.failed"
    assert String.starts_with?(event.payload["error_code"], "signal_exit_")
  end

  test "duplicate transport delivery causes no duplicate logical transition", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    request = ElvesHelpers.run_request(goal, task)

    scenario =
      ElvesHelpers.custom_scenario(:repeated_output, [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        Scenario.output_event("once", source_event_id: "evt-1"),
        Scenario.output_event("once", source_event_id: "evt-1"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               notify: self()
             )

    assert_receive {:elf_terminal, run_id, %{class: :completed}}, 10_000

    assert ElvesHelpers.count_events(goal.id, run_id, ["harness.event_recorded"]) == 3
    assert ElvesHelpers.count_events(goal.id, run_id, ["run.completed"]) == 1
  end

  test "log flood fails closed: oversized event is rejected, never truncated silently", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    request = ElvesHelpers.run_request(goal, task)
    huge = String.duplicate("x", 300_000)

    scenario =
      ElvesHelpers.custom_scenario(:log_flood, [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        Scenario.output_event(huge, source_event_id: "evt-huge"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               max_event_bytes: 32_768,
               notify: self()
             )

    assert_receive {:elf_terminal, run_id, %{class: :failed}}, 10_000

    event = ElvesHelpers.terminal_event(goal.id, run_id)
    assert event.payload["error_code"] == "log_overflow"

    # The oversized payload never landed anywhere durable.
    refute Repo.exists?(
             from e in TrajectoryEvent,
               where:
                 e.goal_id == ^goal.id and e.run_id == ^run_id and
                   fragment("length(?)", e.payload) > 32_768
           )

    assert ElvesHelpers.count_events(goal.id, run_id, ["harness.event_recorded"]) <= 2
  end

  test "OS log flood past the byte cap fails the run explicitly", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    request = ElvesHelpers.run_request(goal, task)
    scenario = ElvesHelpers.custom_scenario(:os_flood, [])
    printer = ~s|import sys; sys.stdout.write("y" * 100_000)|

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["python3", "-c", printer],
               runner_opts: [max_output_bytes: 4_096, kill_grace_ms: 200, reap_timeout_ms: 2_000],
               notify: self()
             )

    assert_receive {:elf_terminal, run_id, %{class: :failed}}, 10_000

    event = ElvesHelpers.terminal_event(goal.id, run_id)
    assert event.payload["error_code"] == "log_overflow"
  end

  test "cancel terminates the whole owned group, descendants included", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    request = ElvesHelpers.run_request(goal, task)
    scenario = Scenario.normal_completion()
    spawner = ~s|import subprocess,time; subprocess.Popen(["sleep","30"]); time.sleep(30)|

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["python3", "-c", spawner],
               runner_opts: @runner_opts,
               event_interval_ms: 50,
               notify: self()
             )

    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    assert {:ok, _} =
             ElvesHelpers.wait_until(fn -> ElvesHelpers.recorded_pgid(goal.id, run_id) end)

    pgid = ElvesHelpers.recorded_pgid(goal.id, run_id)

    assert {:ok, members} =
             ElvesHelpers.wait_until(fn ->
               members = ElvesHelpers.group_members(pgid)
               if length(members) >= 2, do: members
             end)

    assert length(members) >= 2

    assert {:ok, :cancelled} = Elves.cancel_run(run_id, kill_grace_ms: 500)

    assert_receive {:elf_terminal, ^run_id, %{class: :cancelled}}, 10_000

    # Bounded termination: the entire group, descendants included, is gone.
    assert {:ok, []} =
             ElvesHelpers.wait_until(fn ->
               if ElvesHelpers.group_members(pgid) == [], do: []
             end)

    event = ElvesHelpers.terminal_event(goal.id, run_id)
    assert event.type == "run.cancelled"
  end

  test "quiet but working: staleness evidence persists, the run is untouched", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    request = ElvesHelpers.run_request(goal, task)
    scenario = ElvesHelpers.custom_scenario(:quiet, [])

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               notify: self()
             )

    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    assert {:ok, {:ok, first}} =
             ElvesHelpers.wait_until(fn ->
               case Elves.collect_evidence(run_id, "heartbeat_quiet") do
                 {:ok, :persisted, event} -> {:ok, event}
                 _other -> nil
               end
             end)

    assert first.payload["evidence"]["reason"] == "heartbeat_quiet"
    assert first.payload["evidence"]["os_process_group"]["alive"] == true
    assert first.payload["evidence"]["final_response"]["state"] == "missing"

    # A second collection with no new durable state deduplicates.
    assert {:ok, :duplicate, _event} = Elves.collect_evidence(run_id, "heartbeat_quiet")

    assert ElvesHelpers.count_events(goal.id, run_id, ["elf.staleness_observed"]) == 1

    # Nothing was interrupted, replaced, or duplicated.
    pgid = ElvesHelpers.recorded_pgid(goal.id, run_id)
    assert ElvesHelpers.group_members(pgid) != []
    assert ElvesHelpers.terminal_event(goal.id, run_id) == nil
    assert ElvesHelpers.count_events(goal.id, run_id, ["dispatch.requested"]) == 1
    assert ElvesHelpers.count_events(goal.id, run_id, ["run.running"]) == 1

    assert {:ok, :cancelled} = Elves.cancel_run(run_id, kill_grace_ms: 200)
  end

  test "app restart: orphan is adopted, never duplicated; exit reconciles explicitly", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    request = ElvesHelpers.run_request(goal, task)

    scenario =
      ElvesHelpers.custom_scenario(:restart_me, [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        Scenario.output_event("one", source_event_id: "evt-1"),
        Scenario.output_event("two", source_event_id: "evt-2")
      ])

    assert {:ok, first_pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               event_interval_ms: 150,
               orphan_poll_ms: 50,
               notify: self()
             )

    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    assert {:ok, _} =
             ElvesHelpers.wait_until(fn ->
               if ElvesHelpers.count_events(goal.id, run_id, ["harness.event_recorded"]) >= 1,
                 do: true
             end)

    pgid = ElvesHelpers.recorded_pgid(goal.id, run_id)
    assert ElvesHelpers.group_members(pgid) != []

    # Simulate the application dying: the Elf is gone, the group survives.
    Process.exit(first_pid, :kill)
    ref = Process.monitor(first_pid)
    assert_receive {:DOWN, ^ref, :process, ^first_pid, _reason}, 5_000
    assert ElvesHelpers.group_members(pgid) != []

    assert {:ok, :adopted} =
             Elves.reconcile(run_id, supervisor: sup, orphan_poll_ms: 50, notify: self())

    second_pid = Elves.whereis(run_id)
    assert is_pid(second_pid) and second_pid != first_pid

    # Adoption spawned nothing new and persisted adoption evidence.
    assert ElvesHelpers.count_events(goal.id, run_id, ["run.running"]) == 1
    assert ElvesHelpers.count_events(goal.id, run_id, ["dispatch.requested"]) == 1
    assert ElvesHelpers.count_events(goal.id, run_id, ["elf.staleness_observed"]) == 1

    # Now the orphan exits: the adopted Elf reports it explicitly.
    {_out, 0} = System.cmd("kill", ["-KILL", to_string(pgid)])

    assert_receive {:elf_terminal, ^run_id, %{class: :failed}}, 10_000

    assert {:ok, :already_terminal} = Elves.reconcile(run_id, supervisor: sup)

    assert ElvesHelpers.count_events(goal.id, run_id, ["run.failed"]) +
             ElvesHelpers.count_events(goal.id, run_id, ["run.completed"]) +
             ElvesHelpers.count_events(goal.id, run_id, ["run.cancelled"]) == 1
  end

  test "retry after a crash adopts the live group instead of duplicating dispatch", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    request = ElvesHelpers.run_request(goal, task)
    scenario = ElvesHelpers.custom_scenario(:no_dup_retry, [])

    elf_opts = [
      supervisor: sup,
      scenario: scenario,
      command: ["sleep", "30"],
      runner_opts: @runner_opts,
      orphan_poll_ms: 50,
      notify: self()
    ]

    assert {:ok, first_pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(), elf_opts)

    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    Process.exit(first_pid, :kill)
    ref = Process.monitor(first_pid)
    assert_receive {:DOWN, ^ref, :process, ^first_pid, _reason}, 5_000

    # A redelivery carrying the same durable identifiers converges on the
    # live group instead of duplicating the external effect.
    assert {:ok, second_pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(), elf_opts)

    assert is_pid(second_pid) and second_pid != first_pid
    assert Elves.whereis(run_id) == second_pid

    assert ElvesHelpers.count_events(goal.id, run_id, ["dispatch.requested"]) == 1
    assert ElvesHelpers.count_events(goal.id, run_id, ["run.running"]) == 1
    assert {:ok, :cancelled} = Elves.cancel_run(run_id, kill_grace_ms: 200)
  end

  test "terminal reporting is idempotent across restarts", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    request = ElvesHelpers.run_request(goal, task)
    scenario = Scenario.normal_completion()

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               notify: self()
             )

    assert_receive {:elf_terminal, run_id, %{class: :completed}}, 10_000
    assert ElvesHelpers.count_events(goal.id, run_id, ["run.completed"]) == 1

    # A second start converges without a second terminal.
    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               notify: self()
             )

    refute_receive {:elf_terminal, ^run_id, _terminal}, 500
    assert ElvesHelpers.count_events(goal.id, run_id, ["run.completed"]) == 1
    assert ElvesHelpers.count_events(goal.id, run_id, ["dispatch.requested"]) == 1
  end

  test "normalized events are validated, reasoning-stripped, and redacted", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    request = ElvesHelpers.run_request(goal, task)

    scenario =
      ElvesHelpers.custom_scenario(:secrets, [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        %{
          kind: :output,
          offset_ms: 100,
          source_event_id: "evt-secret",
          error: nil,
          result: nil,
          capacity_snapshot: nil,
          extensions: %{
            "shoestring.fake:text" => "connect with sk-abc123XYZ please",
            "shoestring.fake:token" => "ghp_abc123XYZ",
            "thinking" => "this hidden reasoning must never persist",
            "api_key" => "uncontracted data must never persist",
            "shoestring.fake:raw_output" => "transcripts are not canonical state"
          }
        },
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               notify: self()
             )

    assert_receive {:elf_terminal, run_id, %{class: :completed}}, 10_000

    secret_event =
      Repo.one!(
        from e in TrajectoryEvent,
          where:
            e.goal_id == ^goal.id and e.run_id == ^run_id and
              e.type == "harness.event_recorded" and
              e.idempotency_key == ^"elf-event:#{request.dispatch_id}:evt-secret"
      )

    extensions = secret_event.payload["extensions"]
    refute Map.has_key?(extensions, "thinking")
    refute Map.has_key?(extensions, "api_key")
    refute Map.has_key?(extensions, "shoestring.fake:raw_output")
    refute extensions["shoestring.fake:text"] =~ "sk-abc123XYZ"
    assert extensions["shoestring.fake:text"] =~ "[REDACTED]"
    assert extensions["shoestring.fake:token"] == "[REDACTED]"
  end

  test "an Elf without persisted intent stops fail-closed and spawns nothing", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    request = ElvesHelpers.run_request(goal, task)
    run_id = Ecto.UUID.generate()

    elf_opts = [
      goal_id: goal.id,
      run_id: run_id,
      task_id: task.id,
      dispatch_id: request.dispatch_id,
      request: request,
      adapter: Shoestring.Harness.Fake,
      adapter_opts: %{scenario: Scenario.normal_completion()},
      command: ["sleep", "30"],
      runner_opts: @runner_opts
    ]

    assert {:ok, pid} = DynamicSupervisor.start_child(sup, {Elf, elf_opts})
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000

    assert ElvesHelpers.count_events(goal.id, run_id, ["run.running"]) == 0
    assert ElvesHelpers.count_events(goal.id, run_id, ["run.starting"]) == 0
  end

  # -- Private helpers --

  # Blocks until run.running is durable, then returns the run id. The Elf
  # only notifies on terminal, so pre-terminal tests must read durable state.
  defp wait_running(goal, dispatch_id) do
    assert {:ok, run_id} =
             ElvesHelpers.wait_until(fn -> ElvesHelpers.run_id_for_dispatch(dispatch_id) end)

    assert {:ok, _pgid} =
             ElvesHelpers.wait_until(fn -> ElvesHelpers.recorded_pgid(goal.id, run_id) end)

    run_id
  end
end
