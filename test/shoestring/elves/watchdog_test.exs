defmodule Shoestring.Elves.WatchdogTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.Elves
  alias Shoestring.Elves.Watchdog
  alias Shoestring.Test.ElvesHelpers

  @runner_opts [kill_grace_ms: 200, reap_timeout_ms: 2_000]

  @forbidden_shapes [
    "cancel_run",
    "cancel_dispatch",
    "killpg",
    "Process.exit",
    "elf-terminal:",
    "Classifier.",
    "Elf.cancel",
    "terminate_owned_group",
    "terminate_pgid"
  ]

  setup do
    sup = start_supervised!({Shoestring.Elves.Supervisor, name: nil})
    %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()
    {:ok, sup: sup, goal: goal, task: task}
  end

  test "sweep persists evidence, deduplicates across sweeps, and never terminates", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    request = ElvesHelpers.run_request(goal, task)
    scenario = ElvesHelpers.custom_scenario(:watchdog_probe, [])

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts
             )

    assert {:ok, run_id} =
             ElvesHelpers.wait_until(fn ->
               ElvesHelpers.run_id_for_dispatch(request.dispatch_id)
             end)

    assert {:ok, _pgid} =
             ElvesHelpers.wait_until(fn -> ElvesHelpers.recorded_pgid(goal.id, run_id) end)

    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    assert [{:ok, :persisted, ^run_id}] = Watchdog.check_all(reason: "heartbeat_quiet")
    assert ElvesHelpers.count_events(goal.id, run_id, ["elf.staleness_observed"]) == 1

    # Second sweep with identical durable state deduplicates (restart-safe:
    # same observation id, same idempotency key, no new packet).
    assert [{:ok, :duplicate, ^run_id}] = Watchdog.check_all(reason: "heartbeat_quiet")
    assert ElvesHelpers.count_events(goal.id, run_id, ["elf.staleness_observed"]) == 1

    # A live watchdog process sweeps the same way.
    watchdog = start_supervised!({Watchdog, name: nil, interval_ms: 60_000})
    assert [{:ok, :duplicate, ^run_id}] = Watchdog.sweep(watchdog, reason: "heartbeat_quiet")

    # The sweep never touched the run: Elf alive, group alive, no terminal.
    assert Elves.whereis(run_id) != nil
    assert ElvesHelpers.group_members(ElvesHelpers.recorded_pgid(goal.id, run_id)) != []
    assert ElvesHelpers.terminal_event(goal.id, run_id) == nil

    assert {:ok, :cancelled} = Elves.cancel_run(run_id, kill_grace_ms: 200)
  end

  test "check_run on an unknown run fails closed with a per-run error" do
    run_id = Ecto.UUID.generate()

    assert {:error, :run_not_found, ^run_id} =
             Watchdog.check_run(run_id, reason: "heartbeat_quiet")
  end

  test "watchdog and staleness carry no termination paths (pinning)" do
    for file <- ["lib/shoestring/elves/watchdog.ex", "lib/shoestring/elves/staleness.ex"] do
      source = File.read!(Path.join(File.cwd!(), file))

      for shape <- @forbidden_shapes do
        refute String.contains?(source, shape),
               "expected #{file} to contain no #{inspect(shape)} (evidence, never action)"
      end
    end
  end
end
