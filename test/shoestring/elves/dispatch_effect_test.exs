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

  defp restore_env(key, nil), do: Application.delete_env(:shoestring, key)
  defp restore_env(key, value), do: Application.put_env(:shoestring, key, value)
end
