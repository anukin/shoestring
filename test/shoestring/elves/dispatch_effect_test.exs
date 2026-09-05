defmodule Shoestring.Elves.DispatchEffectTest do
  use Shoestring.DataCase, async: false
  use Oban.Testing, repo: Shoestring.Repo, engine: Oban.Engines.Lite

  alias Shoestring.Elves.DispatchEffect
  alias Shoestring.Harness.{DispatchRecord, DispatchWorker, Dispatches, RunRecord}
  alias Shoestring.Repo
  alias Shoestring.Test.ElvesHelpers

  setup do
    _sup = start_supervised!({Shoestring.Elves.Supervisor, name: nil})
    %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()

    previous_effect = Application.get_env(:shoestring, :dispatch_effect)
    previous_elf_opts = Application.get_env(:shoestring, :elf_dispatch_opts)
    previous_clock = Application.get_env(:shoestring, :dispatch_clock)

    Application.put_env(:shoestring, :dispatch_effect, DispatchEffect)
    Application.put_env(:shoestring, :dispatch_clock, Shoestring.Test.FixedClock)

    on_exit(fn ->
      restore_env(:dispatch_effect, previous_effect)
      restore_env(:elf_dispatch_opts, previous_elf_opts)
      restore_env(:dispatch_clock, previous_clock)
    end)

    {:ok, goal: goal, task: task}
  end

  test "Oban delivery runs the Elf to a completed terminal through durable ids only", %{
    goal: goal,
    task: task
  } do
    request = ElvesHelpers.run_request(goal, task)

    Application.put_env(:shoestring, :elf_dispatch_opts,
      scenario: Shoestring.Harness.Fake.Scenario.normal_completion(),
      command: ["sleep", "30"],
      runner_opts: [kill_grace_ms: 200, reap_timeout_ms: 2_000]
    )

    assert {:ok, dispatch, job} =
             Dispatches.enqueue(request, ElvesHelpers.fake_identity(),
               clock: Shoestring.Test.FixedClock
             )

    # The job carries only durable identifiers — no prompt, no scenario, no argv.
    assert Map.keys(job.args) |> Enum.sort() == [
             "dispatch_id",
             "goal_id",
             "request_version",
             "run_id"
           ]

    assert :ok = perform_job(DispatchWorker, job.args)

    run_id = dispatch.run_id
    assert %_{} = ElvesHelpers.terminal_event(goal.id, run_id)
    assert ElvesHelpers.terminal_event(goal.id, run_id).type == "run.completed"

    assert %DispatchRecord{status: "effect_completed"} =
             Repo.get(DispatchRecord, dispatch.dispatch_id)

    assert %RunRecord{} = Repo.get(RunRecord, run_id)
  end

  test "adapter launch refusal fails the attempt with a classified run", %{
    goal: goal,
    task: task
  } do
    request = ElvesHelpers.run_request(goal, task)

    Application.put_env(:shoestring, :elf_dispatch_opts,
      scenario: Shoestring.Harness.Fake.Scenario.start_failure(),
      command: ["sleep", "30"],
      runner_opts: [kill_grace_ms: 200, reap_timeout_ms: 2_000]
    )

    assert {:ok, dispatch, job} =
             Dispatches.enqueue(request, ElvesHelpers.fake_identity(),
               clock: Shoestring.Test.FixedClock
             )

    assert {:cancel, _reason} = perform_job(DispatchWorker, job.args)

    event = ElvesHelpers.terminal_event(goal.id, dispatch.run_id)
    assert event.type == "run.failed"
    assert event.payload["error_code"] == "process_launch_failed"
  end

  test "no timer cancels the run: a quiet run outlives any monitor interval", %{
    goal: goal,
    task: task
  } do
    request = ElvesHelpers.run_request(goal, task)

    Application.put_env(
      :shoestring,
      :elf_dispatch_opts,
      scenario: ElvesHelpers.custom_scenario(:quiet_dispatch, []),
      command: ["sleep", "30"],
      runner_opts: [kill_grace_ms: 200, reap_timeout_ms: 2_000]
    )

    assert {:ok, dispatch, job} =
             Dispatches.enqueue(request, ElvesHelpers.fake_identity(),
               clock: Shoestring.Test.FixedClock
             )

    run_id = dispatch.run_id
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    # The worker blocks in the effect while the Elf supervises the run, so
    # drive it in a task — the mirror of the Elf-level quiet-but-working eval,
    # one layer up where the removed synthetic timer used to live.
    worker = Task.async(fn -> perform_job(DispatchWorker, job.args) end)

    assert {:ok, _pgid} =
             ElvesHelpers.wait_until(fn -> ElvesHelpers.recorded_pgid(goal.id, run_id) end)

    # Past any plausible monitor interval: the run must be untouched — alive,
    # unterminated, with no cancelling marker. Only an explicit request or
    # worker shutdown may end it, never a local timer.
    Process.sleep(1_000)

    assert is_pid(Shoestring.Elves.whereis(run_id))
    assert ElvesHelpers.group_members(ElvesHelpers.recorded_pgid(goal.id, run_id)) != []
    assert ElvesHelpers.terminal_event(goal.id, run_id) == nil
    assert ElvesHelpers.count_events(goal.id, run_id, ["run.cancelling"]) == 0
    assert ElvesHelpers.count_events(goal.id, run_id, ["run.cancelled"]) == 0
    assert Task.yield(worker, 0) == nil

    # Explicit cancellation still works and releases the blocked worker.
    assert {:ok, :cancelled} = Shoestring.Elves.cancel_run(run_id, kill_grace_ms: 200)
    assert :ok = Task.await(worker, 10_000)
    assert ElvesHelpers.terminal_event(goal.id, run_id).type == "run.cancelled"
  end

  test "a retry after the attempt cannot duplicate the external effect", %{
    goal: goal,
    task: task
  } do
    request = ElvesHelpers.run_request(goal, task)

    Application.put_env(:shoestring, :elf_dispatch_opts,
      scenario: Shoestring.Harness.Fake.Scenario.normal_completion(),
      command: ["sleep", "30"],
      runner_opts: [kill_grace_ms: 200, reap_timeout_ms: 2_000]
    )

    assert {:ok, dispatch, job} =
             Dispatches.enqueue(request, ElvesHelpers.fake_identity(),
               clock: Shoestring.Test.FixedClock
             )

    assert :ok = perform_job(DispatchWorker, job.args)

    # Redelivering the same durable identifiers converges: no second run,
    # no second terminal, no second spawn.
    assert {:ok, _dispatch, _job} =
             Dispatches.enqueue(request, ElvesHelpers.fake_identity(),
               clock: Shoestring.Test.FixedClock
             )

    assert :ok = perform_job(DispatchWorker, job.args)

    run_id = dispatch.run_id
    assert ElvesHelpers.count_events(goal.id, run_id, ["dispatch.requested"]) == 1
    assert ElvesHelpers.count_events(goal.id, run_id, ["run.completed"]) == 1
    assert ElvesHelpers.count_events(goal.id, run_id, ["run.running"]) == 1
  end

  test "an interrupted turn completes the attempt honestly, never as a failure", %{
    goal: goal,
    task: task
  } do
    request = ElvesHelpers.run_request(goal, task)

    interrupted =
      Shoestring.Harness.Fake.Scenario.result_event("interrupted",
        offset_ms: 100,
        source_event_id: "turn-interrupted"
      )
      |> Map.put(:extensions, %{"codex-app-server:interrupted" => true})

    scenario =
      ElvesHelpers.custom_scenario(:interrupted_dispatch, [
        %{
          kind: :command,
          offset_ms: 0,
          source_event_id: "cmd-mix-test",
          error: nil,
          result: nil,
          capacity_snapshot: nil,
          extensions: %{"shoestring.fake:command" => "mix test"}
        },
        interrupted
      ])

    Application.put_env(:shoestring, :elf_dispatch_opts,
      scenario: scenario,
      command: ["sleep", "30"],
      runner_opts: [kill_grace_ms: 200, reap_timeout_ms: 2_000]
    )

    assert {:ok, dispatch, job} =
             Dispatches.enqueue(request, ElvesHelpers.fake_identity(),
               clock: Shoestring.Test.FixedClock
             )

    # A deliberate stop ends the attempt cleanly: :ok, not an error, and
    # the persisted terminal is interrupted rather than failed.
    assert :ok = perform_job(DispatchWorker, job.args)

    run_id = dispatch.run_id
    assert ElvesHelpers.terminal_event(goal.id, run_id).type == "run.interrupted"
    assert ElvesHelpers.count_events(goal.id, run_id, ["run.failed"]) == 0

    assert %DispatchRecord{status: "effect_completed"} =
             Repo.get(DispatchRecord, dispatch.dispatch_id)
  end

  defp restore_env(key, nil), do: Application.delete_env(:shoestring, key)
  defp restore_env(key, value), do: Application.put_env(:shoestring, key, value)
end
