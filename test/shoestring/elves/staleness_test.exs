defmodule Shoestring.Elves.StalenessTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.Elves
  alias Shoestring.Elves.Staleness
  alias Shoestring.Harness.Fake.Scenario
  alias Shoestring.Test.ElvesHelpers

  @runner_opts [kill_grace_ms: 200, reap_timeout_ms: 2_000]

  setup do
    sup = start_supervised!({Shoestring.Elves.Supervisor, name: nil})
    %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()
    {:ok, sup: sup, goal: goal, task: task}
  end

  test "collect persists a bounded evidence packet and deduplicates", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    request = ElvesHelpers.run_request(goal, task)
    scenario = ElvesHelpers.custom_scenario(:stale_probe, [])

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

    assert {:ok, :persisted, event} = Staleness.collect(run_id, "manual_probe")
    assert event.type == "elf.staleness_observed"

    evidence = event.payload["evidence"]
    assert evidence["reason"] == "manual_probe"
    assert evidence["run_status"] == "requested"
    assert is_integer(evidence["last_event_sequence"])
    assert evidence["os_process_group"]["alive"] == true
    assert evidence["provider_session_id"] == "fake-session-stale_probe"
    assert evidence["safe_boundary"]["kind"] != nil
    assert Map.has_key?(evidence, "oban_attempt")
    assert Map.has_key?(evidence, "worktree")
    assert is_list(evidence["completed_commands"])
    assert evidence["final_response"]["state"] == "missing"
    assert evidence["pending_approval"] == false

    # Stable observation id: same durable state, same reason, no new packet.
    assert {:ok, :duplicate, _event} = Staleness.collect(run_id, "manual_probe")
    assert ElvesHelpers.count_events(goal.id, run_id, ["elf.staleness_observed"]) == 1

    # A different reason is a different observation.
    assert {:ok, :persisted, _event} = Staleness.collect(run_id, "final_response_missing")
    assert ElvesHelpers.count_events(goal.id, run_id, ["elf.staleness_observed"]) == 2

    # Collection never touched the run: still alive, still non-terminal.
    assert ElvesHelpers.group_members(ElvesHelpers.recorded_pgid(goal.id, run_id)) != []
    assert ElvesHelpers.terminal_event(goal.id, run_id) == nil

    assert {:ok, :cancelled} = Elves.cancel_run(run_id, kill_grace_ms: 200)
  end

  test "observation ids are stable for identical inputs" do
    run_id = Ecto.UUID.generate()

    assert Staleness.observation_id(run_id, 7, "heartbeat_quiet") ==
             Staleness.observation_id(run_id, 7, "heartbeat_quiet")

    refute Staleness.observation_id(run_id, 7, "heartbeat_quiet") ==
             Staleness.observation_id(run_id, 8, "heartbeat_quiet")
  end

  test "collect on an unknown run fails closed" do
    assert {:error, :run_not_found} = Staleness.collect(Ecto.UUID.generate(), "manual_probe")
  end

  test "evidence records quota-style terminal conditions without killing", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    request = ElvesHelpers.run_request(goal, task)
    scenario = Scenario.sudden_quota_refusal()

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
    assert event.payload["error_category"] == "quota_refused"
  end
end
