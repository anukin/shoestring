defmodule Shoestring.Elves.ReconcilerTest do
  @moduledoc """
  The boot pass over runs a stopped node left `running`. Stand-in `sleep`
  groups only; no provider.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Elves
  alias Shoestring.Elves.Reconciler
  alias Shoestring.Test.ElvesHelpers

  @runner_opts [kill_grace_ms: 200, reap_timeout_ms: 2_000]

  setup do
    sup = start_supervised!({Shoestring.Elves.Supervisor, name: nil})
    %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()
    {:ok, sup: sup, goal: goal, task: task}
  end

  test "a run whose group stopped with the node has its exit recorded at boot", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    {run_id, pgid} = stranded_run(sup, goal, task)

    {_output, 0} = System.cmd("kill", ["-KILL", "-#{pgid}"])
    assert {:ok, true} = ElvesHelpers.wait_until(fn -> ElvesHelpers.group_members(pgid) == [] end)

    reconciler = start_supervised!({Reconciler, name: nil, supervisor: sup})
    # The boot pass ran in init; a second pass finds nothing left to repair.
    assert {:ok, %{repaired_count: 0, failures: []}} = Reconciler.reconcile_now(reconciler)

    event = ElvesHelpers.terminal_event(goal.id, run_id)
    assert event.type == "run.failed"
    assert event.payload["error_code"] == "supervisor_crash"
    assert Elves.whereis(run_id) == nil
    assert ElvesHelpers.count_events(goal.id, run_id, ["run.running"]) == 1
    assert ElvesHelpers.count_events(goal.id, run_id, ["dispatch.requested"]) == 1
  end

  test "a run whose group outlived the node is adopted, never respawned", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    {run_id, pgid} = stranded_run(sup, goal, task)

    assert {:ok, %{repaired_count: 1, failures: []}} =
             Elves.reconcile_unfinished(supervisor: sup, orphan_poll_ms: 50, notify: self())

    assert is_pid(Elves.whereis(run_id))
    assert ElvesHelpers.group_members(pgid) != []
    assert ElvesHelpers.terminal_event(goal.id, run_id) == nil
    assert ElvesHelpers.count_events(goal.id, run_id, ["run.running"]) == 1

    # The adopted Elf records the group's exit when it comes.
    {_output, 0} = System.cmd("kill", ["-KILL", "-#{pgid}"])
    assert_receive {:elf_terminal, ^run_id, %{class: :failed}}, 10_000
    assert {:ok, %{repaired_count: 0}} = Elves.reconcile_unfinished(supervisor: sup)
  end

  test "a run still waiting for delivery is left alone", %{sup: sup, goal: goal, task: task} do
    request = ElvesHelpers.run_request(goal, task)

    {:ok, dispatch, _job} =
      Shoestring.Harness.Dispatches.enqueue(request, ElvesHelpers.fake_identity())

    assert {:ok, %{repaired_count: 0, failures: []}} =
             Elves.reconcile_unfinished(supervisor: sup, spawn_grace_ms: 0)

    assert ElvesHelpers.terminal_event(goal.id, dispatch.run_id) == nil
    assert Elves.whereis(dispatch.run_id) == nil
  end

  # A `sleep` run whose Elf is then lost the way a stopping node loses it,
  # leaving the run recorded `running` and its group alive.
  defp stranded_run(sup, goal, task) do
    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: ElvesHelpers.custom_scenario(:stranded, []),
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               orphan_poll_ms: 50
             )

    assert {:ok, run_id} =
             ElvesHelpers.wait_until(fn ->
               ElvesHelpers.run_id_for_dispatch(request.dispatch_id)
             end)

    assert {:ok, pgid} =
             ElvesHelpers.wait_until(fn -> ElvesHelpers.recorded_pgid(goal.id, run_id) end)

    on_exit(fn -> ElvesHelpers.cleanup_group(pgid) end)

    ElvesHelpers.kill_idle(pid)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    assert ElvesHelpers.group_members(pgid) != []
    {run_id, pgid}
  end
end
