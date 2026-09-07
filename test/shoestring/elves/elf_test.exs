defmodule Shoestring.Elves.ElfTest do
  use Shoestring.DataCase, async: false

  import Ecto.Query

  alias Shoestring.Elves
  alias Shoestring.Elves.Elf
  alias Shoestring.Harness.{ClaudeHeadless, CodexAppServer}
  alias Shoestring.Harness.Fake.Scenario
  alias Shoestring.Repo
  alias Shoestring.Test.ElfWorktreeFixture
  alias Shoestring.Test.ElvesHelpers
  alias Shoestring.Test.LiveBufferedAdapter
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

  test "clean OS exit with zero adapter events fails instead of completing (live-demo regression)",
       %{
         sup: sup,
         goal: goal,
         task: task
       } do
    # The live demo's placeholder command exited 0 instantly while the
    # provider turn was still handshaking; the Elf reported run.completed
    # having observed zero adapter events. A launch that never began is a
    # launch failure, never a success.
    #
    # The owned command sleeps briefly before exiting 0 so the (empty)
    # adapter stream deterministically drains while the group is still
    # alive; the classification under test then runs on the known exit.
    request = ElvesHelpers.run_request(goal, task)
    scenario = ElvesHelpers.custom_scenario(:silent_clean_exit, [])

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["python3", "-c", "import time; time.sleep(2)"],
               runner_opts: @runner_opts,
               notify: self()
             )

    assert_receive {:elf_terminal, run_id, %{class: :failed}}, 10_000

    event = ElvesHelpers.terminal_event(goal.id, run_id)
    assert event.type == "run.failed"
    assert event.payload["error_category"] == "transport"
    assert event.payload["error_code"] == "no_adapter_events"
    assert ElvesHelpers.count_events(goal.id, run_id, ["run.completed"]) == 0
    assert ElvesHelpers.count_events(goal.id, run_id, ["harness.event_recorded"]) == 0
  end

  test "handshake-only stall that exits clean fails as no_adapter_progress, never completed",
       %{sup: sup, goal: goal, task: task} do
    # D1: after_ingest/3 counted EVERY ingested event, including :lifecycle
    # handshakes (the Codex normalizer emits them for thread/turn/item
    # notices before any model work), so classify/4 saw a positive count and
    # a verdictless clean exit reported run.completed — a durable success
    # for a run that did no work. Only progress kinds (neither :lifecycle
    # nor :capacity) may complete a run that never produced a verdict.
    request = ElvesHelpers.run_request(goal, task)

    handshake = [
      Scenario.lifecycle_event(source_event_id: "evt-thread"),
      Scenario.lifecycle_event(source_event_id: "evt-turn"),
      Scenario.lifecycle_event(source_event_id: "evt-item")
    ]

    scenario = ElvesHelpers.custom_scenario(:handshake_then_stall, handshake)

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["python3", "-c", "import time; time.sleep(2)"],
               runner_opts: @runner_opts,
               notify: self()
             )

    assert_receive {:elf_terminal, run_id, _terminal}, 10_000

    event = ElvesHelpers.terminal_event(goal.id, run_id)
    assert event.type == "run.failed"
    assert event.payload["error_category"] == "transport"
    assert event.payload["error_code"] == "no_adapter_progress"

    # Both directions: the handshake events DID land durably (the failure is
    # missing work, not a missing transport) and no completion exists.
    assert ElvesHelpers.count_events(goal.id, run_id, ["harness.event_recorded"]) == 3
    assert ElvesHelpers.count_events(goal.id, run_id, ["run.completed"]) == 0
  end

  test "crash recovery: re-streamed events restore the observed count, no false no_adapter_events",
       %{sup: sup, goal: goal, task: task} do
    # N1: rebuild_seen/1 restored state.seen from persisted events but left
    # state.event_count at 0, so an Elf that resumed after a crash, skipped
    # its re-streamed events as already-seen, then saw a clean OS exit with
    # no verdict classified no_adapter_events (run.failed) — a terminal-state
    # lie about a run that genuinely produced adapter events.
    request = ElvesHelpers.run_request(goal, task)

    restreamed = [
      Scenario.lifecycle_event(source_event_id: "evt-life"),
      Scenario.output_event("before crash", source_event_id: "evt-1")
    ]

    first_opts = [
      supervisor: sup,
      scenario: ElvesHelpers.custom_scenario(:crash_before_verdict, restreamed),
      command: ["sleep", "30"],
      runner_opts: @runner_opts,
      notify: self()
    ]

    assert {:ok, first_pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(), first_opts)

    run_id = wait_running(goal, request.dispatch_id)

    assert {:ok, _} =
             ElvesHelpers.wait_until(fn ->
               if ElvesHelpers.count_events(goal.id, run_id, ["harness.event_recorded"]) >= 2,
                 do: true
             end)

    pgid = ElvesHelpers.recorded_pgid(goal.id, run_id)
    assert is_integer(pgid)

    # Simulate the application dying mid-run and the orphaned group dying
    # unobserved with it. The retry relaunches with a dead group, restores
    # seen from durable events, and re-streams the same transport pair.
    Process.exit(first_pid, :kill)
    ref = Process.monitor(first_pid)
    assert_receive {:DOWN, ^ref, :process, ^first_pid, _reason}, 5_000

    ElvesHelpers.cleanup_group(pgid)

    assert {:ok, []} =
             ElvesHelpers.wait_until(fn ->
               if ElvesHelpers.group_members(pgid) == [], do: []
             end)

    # The relaunched command sleeps briefly before exiting 0 so the
    # re-streamed (already-seen) pair deterministically drains while the
    # group is still alive; the classification under test then runs on the
    # known exit, exactly like the silent-clean-exit regression above.
    assert {:ok, second_pid} =
             Elves.start_run(
               request,
               ElvesHelpers.fake_identity(),
               Keyword.merge(first_opts,
                 scenario: ElvesHelpers.custom_scenario(:crash_recovery_restream, restreamed),
                 command: ["python3", "-c", "import time; time.sleep(2)"]
               )
             )

    assert is_pid(second_pid) and second_pid != first_pid
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    # The re-streamed pair was skipped as already-seen (no duplicates), the
    # clean exit observed prior adapter events, and the run completed.
    assert_receive {:elf_terminal, ^run_id, %{class: :completed}}, 15_000

    assert ElvesHelpers.count_events(goal.id, run_id, ["harness.event_recorded"]) == 2

    event = ElvesHelpers.terminal_event(goal.id, run_id)
    assert event.type == "run.completed"
  end

  test "crash recovery: handshake-only history restores as zero progress, no false completed",
       %{sup: sup, goal: goal, task: task} do
    # D1's recovery twin: rebuild_seen/1 restores the counters from durable
    # events, and the persisted payloads carry "kind". A run whose entire
    # pre-crash history was lifecycle/capacity handshakes must restore as
    # ZERO progress and fail no_adapter_progress on a verdictless clean
    # exit — the pre-fix code restored only the total event count, so the
    # resumed run reported run.completed without ever having done work.
    request = ElvesHelpers.run_request(goal, task)

    handshake_only = [
      Scenario.lifecycle_event(source_event_id: "evt-life"),
      Scenario.capacity_event(
        "00000000-0000-4000-8000-f0000000ff21",
        65.0,
        ~U[2026-09-01 10:00:00.000000Z],
        source_event_id: "evt-cap"
      )
    ]

    first_opts = [
      supervisor: sup,
      scenario: ElvesHelpers.custom_scenario(:crash_before_verdict, handshake_only),
      command: ["sleep", "30"],
      runner_opts: @runner_opts,
      notify: self()
    ]

    assert {:ok, first_pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(), first_opts)

    run_id = wait_running(goal, request.dispatch_id)

    assert {:ok, _} =
             ElvesHelpers.wait_until(fn ->
               if ElvesHelpers.count_events(goal.id, run_id, ["harness.event_recorded"]) >= 2,
                 do: true
             end)

    pgid = ElvesHelpers.recorded_pgid(goal.id, run_id)
    assert is_integer(pgid)

    # Simulate the application dying mid-run and the orphaned group dying
    # unobserved with it. The retry relaunches with a dead group, restores
    # seen and both counters from durable events, and re-streams the same
    # handshake-only pair.
    Process.exit(first_pid, :kill)
    ref = Process.monitor(first_pid)
    assert_receive {:DOWN, ^ref, :process, ^first_pid, _reason}, 5_000

    ElvesHelpers.cleanup_group(pgid)

    assert {:ok, []} =
             ElvesHelpers.wait_until(fn ->
               if ElvesHelpers.group_members(pgid) == [], do: []
             end)

    assert {:ok, second_pid} =
             Elves.start_run(
               request,
               ElvesHelpers.fake_identity(),
               Keyword.merge(first_opts,
                 scenario: ElvesHelpers.custom_scenario(:crash_recovery_restream, handshake_only),
                 command: ["python3", "-c", "import time; time.sleep(2)"]
               )
             )

    assert is_pid(second_pid) and second_pid != first_pid
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    assert_receive {:elf_terminal, ^run_id, _terminal}, 15_000

    event = ElvesHelpers.terminal_event(goal.id, run_id)
    assert event.type == "run.failed"
    assert event.payload["error_category"] == "transport"
    assert event.payload["error_code"] == "no_adapter_progress"

    # The re-streamed handshake pair was skipped as already-seen (no
    # duplicates) and remains durable evidence that events DID arrive.
    assert ElvesHelpers.count_events(goal.id, run_id, ["harness.event_recorded"]) == 2
    assert ElvesHelpers.count_events(goal.id, run_id, ["run.completed"]) == 0
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

  test "adapter-owned provider polls live buffers and runs only in the recognized worktree", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    run_id = Ecto.UUID.generate()
    fixture = ElfWorktreeFixture.create!(run_id)
    on_exit(fn -> ElfWorktreeFixture.cleanup!(fixture) end)
    on_exit(fn -> LiveBufferedAdapter.cleanup(run_id) end)

    source_before = ElfWorktreeFixture.source_snapshot(fixture.source_repo)

    request =
      ElvesHelpers.run_request(goal, task,
        workspace_ref: fixture.worktree.workspace_ref,
        dispatch_id: run_id
      )

    duplicate_marker = Path.join(fixture.worktree.path, "duplicate-runner-started")

    assert {:ok, _pid} =
             Elves.start_run(request, LiveBufferedAdapter.identity(),
               supervisor: sup,
               run_id: run_id,
               adapter: LiveBufferedAdapter,
               adapter_opts: %{test_pid: self()},
               process_owner: :adapter,
               command: ["touch", duplicate_marker],
               runner_opts: [
                 cd: fixture.worktree.path,
                 kill_grace_ms: 200,
                 reap_timeout_ms: 2_000
               ],
               adapter_poll_ms: 10,
               notify: self()
             )

    assert_receive {:live_buffered_adapter_started, ^run_id, workdir, pgid}, 10_000
    assert workdir == fixture.worktree.path
    refute File.exists?(duplicate_marker)

    assert_receive {:live_buffered_adapter_polled, ^run_id, 1}, 10_000
    assert ElvesHelpers.recorded_pgid(goal.id, run_id) == pgid
    assert_receive {:live_buffered_adapter_polled, ^run_id, 2}, 10_000
    assert_receive {:elf_terminal, ^run_id, %{class: :completed}}, 10_000

    assert ElvesHelpers.count_events(goal.id, run_id, ["harness.event_recorded"]) == 3
    assert ElfWorktreeFixture.source_snapshot(fixture.source_repo) == source_before
    assert ElvesHelpers.group_members(pgid) == []
  end

  test "adapter-owned cancellation reaches the adapter and reaps its process group", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    run_id = Ecto.UUID.generate()
    fixture = ElfWorktreeFixture.create!(run_id)
    on_exit(fn -> ElfWorktreeFixture.cleanup!(fixture) end)
    on_exit(fn -> LiveBufferedAdapter.cleanup(run_id) end)

    request =
      ElvesHelpers.run_request(goal, task,
        workspace_ref: fixture.worktree.workspace_ref,
        dispatch_id: run_id
      )

    assert {:ok, _pid} =
             Elves.start_run(request, LiveBufferedAdapter.identity(),
               supervisor: sup,
               run_id: run_id,
               adapter: LiveBufferedAdapter,
               adapter_opts: %{test_pid: self(), test_scenario: :quiet},
               process_owner: :adapter,
               command: ["sleep", "30"],
               runner_opts: [
                 cd: fixture.worktree.path,
                 kill_grace_ms: 200,
                 reap_timeout_ms: 2_000
               ],
               adapter_poll_ms: 10,
               notify: self()
             )

    assert_receive {:live_buffered_adapter_started, ^run_id, _workdir, pgid}, 10_000
    assert_receive {:live_buffered_adapter_polled, ^run_id, 1}, 10_000
    assert {:ok, :cancelled} = Elves.cancel_run(run_id, kill_grace_ms: 200)
    assert_receive {:live_buffered_adapter_cancelled, ^run_id}, 10_000
    assert_receive {:elf_terminal, ^run_id, %{class: :cancelled}}, 10_000
    assert ElvesHelpers.group_members(pgid) == []
  end

  test "adapter-owned launch fails closed when the worktree identity does not match", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    run_id = Ecto.UUID.generate()
    fixture = ElfWorktreeFixture.create!(run_id)
    on_exit(fn -> ElfWorktreeFixture.cleanup!(fixture) end)
    on_exit(fn -> LiveBufferedAdapter.cleanup(run_id) end)

    request =
      ElvesHelpers.run_request(goal, task,
        workspace_ref: "run-different",
        dispatch_id: run_id
      )

    assert {:ok, _pid} =
             Elves.start_run(request, LiveBufferedAdapter.identity(),
               supervisor: sup,
               run_id: run_id,
               adapter: LiveBufferedAdapter,
               adapter_opts: %{test_pid: self()},
               process_owner: :adapter,
               runner_opts: [cd: fixture.worktree.path],
               notify: self()
             )

    assert_receive {:elf_terminal, ^run_id, %{class: :failed}}, 10_000
    refute_received {:live_buffered_adapter_started, ^run_id, _workdir, _pgid}

    event = ElvesHelpers.terminal_event(goal.id, run_id)
    assert event.payload["error_code"] == "worktree_mismatch"
    assert ElvesHelpers.count_events(goal.id, run_id, ["run.running"]) == 0
  end

  test "Codex adapter completes through the Elf with a hermetic app-server process", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    run_id = Ecto.UUID.generate()
    fixture = ElfWorktreeFixture.create!(run_id)
    on_exit(fn -> ElfWorktreeFixture.cleanup!(fixture) end)
    source_before = ElfWorktreeFixture.source_snapshot(fixture.source_repo)

    request =
      ElvesHelpers.run_request(goal, task,
        workspace_ref: fixture.worktree.workspace_ref,
        dispatch_id: run_id
      )

    script = """
    import json
    import pathlib
    import sys
    import time

    thread_id = "01950000-0000-7000-8000-000000000099"
    turn_id = "01950000-0000-7000-8000-000000000088"
    item_id = "exec-01950000-0000-7000-8000-000000000077"

    def emit(frame):
        print(json.dumps(frame), flush=True)

    for line in sys.stdin:
        frame = json.loads(line)
        method = frame.get("method")
        request_id = frame.get("id")

        if method == "initialize":
            emit({"jsonrpc": "2.0", "id": request_id, "result": {}})
        elif method == "thread/start":
            cwd = frame["params"]["cwd"]
            pathlib.Path(cwd, "codex-through-elf.txt").write_text("codex\\n")
            emit({"jsonrpc": "2.0", "id": request_id, "result": {"thread": {"id": thread_id}}})
        elif method == "turn/start":
            emit({"jsonrpc": "2.0", "id": request_id, "result": {"turn": {"id": turn_id, "status": "inProgress"}}})
            emit({"method": "turn/started", "params": {"turn": {"id": turn_id, "status": "inProgress"}}})
            emit({"method": "item/started", "params": {"threadId": thread_id, "item": {"id": item_id, "type": "fileChange", "status": "inProgress"}}})
            emit({"method": "item/completed", "params": {"threadId": thread_id, "item": {"id": item_id, "type": "fileChange", "status": "completed", "changes": [{"path": str(pathlib.Path(cwd, "codex-through-elf.txt")), "kind": {"type": "add"}, "diff": "codex\\n"}]}}})
            emit({"method": "item/completed", "params": {"threadId": thread_id, "item": {"id": "item-1", "type": "agentMessage", "phase": "final", "text": "done"}}})
            emit({"method": "turn/completed", "params": {"turn": {"id": turn_id, "status": "completed"}}})
            time.sleep(30)
    """

    assert {:ok, _pid} =
             Elves.start_run(request, CodexAppServer.identity(),
               supervisor: sup,
               run_id: run_id,
               adapter: CodexAppServer,
               adapter_opts: %{
                 live: true,
                 command: "python3",
                 args: ["-u", "-c", script],
                 handshake_timeout_ms: 5_000
               },
               process_owner: :adapter,
               command: ["touch", Path.join(fixture.worktree.path, "duplicate-codex")],
               runner_opts: [
                 cd: fixture.worktree.path,
                 kill_grace_ms: 200,
                 reap_timeout_ms: 2_000
               ],
               adapter_poll_ms: 10,
               notify: self()
             )

    assert_receive {:elf_terminal, ^run_id, %{class: :completed}}, 10_000
    assert File.read!(Path.join(fixture.worktree.path, "codex-through-elf.txt")) == "codex\n"
    refute File.exists?(Path.join(fixture.worktree.path, "duplicate-codex"))
    assert {:error, :not_found} = CodexAppServer.lookup_session(run_id)
    assert ElfWorktreeFixture.source_snapshot(fixture.source_repo) == source_before

    completion =
      Repo.one!(
        from e in TrajectoryEvent,
          where:
            e.goal_id == ^goal.id and e.run_id == ^run_id and
              e.idempotency_key ==
                ^"elf-event:#{request.dispatch_id}:item-completed-exec-01950000-0000-7000-8000-000000000077"
      )

    assert [change] = completion.payload["extensions"]["codex-app-server:changes"]
    assert change["kind"] == "add"
    refute is_map(change["kind"])
  end

  test "Claude adapter completes through the Elf with a hermetic headless process", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    run_id = Ecto.UUID.generate()
    fixture = ElfWorktreeFixture.create!(run_id)
    on_exit(fn -> ElfWorktreeFixture.cleanup!(fixture) end)
    source_before = ElfWorktreeFixture.source_snapshot(fixture.source_repo)

    request =
      ElvesHelpers.run_request(goal, task,
        workspace_ref: fixture.worktree.workspace_ref,
        dispatch_id: run_id
      )

    script = """
    import json
    import pathlib
    import time

    session_id = "aaaaaaaa-0000-4000-a000-000000000099"
    pathlib.Path("claude-through-elf.txt").write_text("claude\\n")

    frames = [
        {"type": "system", "subtype": "init", "cwd": str(pathlib.Path.cwd()), "session_id": session_id, "uuid": "bbbbbbbb-0000-4000-8000-000000000091"},
        {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "done"}]}, "session_id": session_id, "uuid": "bbbbbbbb-0000-4000-8000-000000000092"},
        {"type": "result", "subtype": "success", "is_error": False, "terminal_reason": "completed", "result": "done", "session_id": session_id, "uuid": "bbbbbbbb-0000-4000-8000-000000000093"}
    ]

    for frame in frames:
        print(json.dumps(frame), flush=True)

    time.sleep(30)
    """

    assert {:ok, _pid} =
             Elves.start_run(request, ClaudeHeadless.identity(),
               supervisor: sup,
               run_id: run_id,
               adapter: ClaudeHeadless,
               adapter_opts: %{
                 live: true,
                 argv: ["python3", "-u", "-c", script],
                 permission_bypass: false
               },
               process_owner: :adapter,
               command: ["touch", Path.join(fixture.worktree.path, "duplicate-claude")],
               runner_opts: [
                 cd: fixture.worktree.path,
                 kill_grace_ms: 200,
                 reap_timeout_ms: 2_000
               ],
               adapter_poll_ms: 10,
               notify: self()
             )

    assert_receive {:elf_terminal, ^run_id, %{class: :completed}}, 10_000
    assert File.read!(Path.join(fixture.worktree.path, "claude-through-elf.txt")) == "claude\n"
    refute File.exists?(Path.join(fixture.worktree.path, "duplicate-claude"))
    assert {:error, :not_found} = ClaudeHeadless.lookup_session(run_id)
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
