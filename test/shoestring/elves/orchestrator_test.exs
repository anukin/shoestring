defmodule Shoestring.Elves.OrchestratorTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.Elves
  alias Shoestring.Elves.{Orchestrator, Staleness}
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

  defp command_spec(id, offset_ms) do
    %{
      kind: :command,
      offset_ms: offset_ms,
      source_event_id: id,
      error: nil,
      result: nil,
      capacity_snapshot: nil,
      extensions: %{"shoestring.fake:command" => "mix test"}
    }
  end

  defp start_quiet_run(sup, goal, task, name, events) do
    request = ElvesHelpers.run_request(goal, task)
    scenario = ElvesHelpers.custom_scenario(name, events)

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

    # Wait until every scripted adapter event has landed in the trajectory,
    # so the evidence packet below observes the full durable state.
    assert {:ok, _count} =
             ElvesHelpers.wait_until(fn ->
               count = ElvesHelpers.count_events(goal.id, run_id, ["harness.event_recorded"])
               if count >= length(events), do: count, else: nil
             end)

    # The stream is consumed without a verdict; the group stays alive and no
    # terminal is reported.
    assert {:ok, :persisted, _event} = Staleness.collect(run_id, "manual_probe")
    _ = :sys.get_state(Elves.whereis(run_id))
    run_id
  end

  test "completed with no final report: evidence reaches the orchestrator, nothing auto-acts", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    # The child did the work (recorded test command, passed) but never sent a
    # final assistant response: command events, no result, no terminal.
    run_id = start_quiet_run(sup, goal, task, :no_final_report, [command_spec("cmd-test-1", 0)])

    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    assert {:ok, packet} = Orchestrator.summarize(run_id)
    assert packet.run_id == run_id
    assert packet.terminal == nil
    assert packet.progress.completed_commands == ["cmd-test-1"]
    assert packet.progress.final_response_state == "missing"
    assert length(packet.evidence_refs) == 1
    assert "request_status" in packet.choices
    assert "synthesize_completion" in packet.choices

    # The orchestrator can request status: recorded with evidence refs,
    # rationale, action, and outcome — and the run is untouched.
    assert {:ok, event} =
             Orchestrator.record_choice(run_id, %{
               action: "request_status",
               evidence_refs: packet.evidence_refs,
               rationale:
                 "Test command recorded as passed; asking the child for its final report.",
               outcome: "pending"
             })

    assert event.type == "elf.recovery_decided"
    assert event.payload["action"] == "request_status"
    assert event.payload["evidence_refs"] == packet.evidence_refs
    assert event.payload["outcome"] == "pending"

    # Nothing auto-killed or auto-replaced: Elf and group alive, no terminal,
    # replacement still refused.
    assert Elves.whereis(run_id) != nil
    assert ElvesHelpers.group_members(ElvesHelpers.recorded_pgid(goal.id, run_id)) != []
    assert ElvesHelpers.terminal_event(goal.id, run_id) == nil
    assert {:ok, false} = Orchestrator.can_replace?(run_id)
    assert {:error, :prior_run_active} = Orchestrator.request_replacement(run_id)

    assert {:ok, :cancelled} = Elves.cancel_run(run_id, kill_grace_ms: 200)
  end

  test "quiet but working: evidence persisted, Elf and group stay alive, no terminal", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    # Events suppressed while the child process group is still alive.
    run_id = start_quiet_run(sup, goal, task, :quiet_probe, [])

    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    assert {:ok, packet} = Orchestrator.summarize(run_id)
    assert packet.terminal == nil
    assert packet.evidence["os_process_group"]["alive"] == true
    assert packet.progress.final_response_state == "missing"

    assert Elves.whereis(run_id) != nil
    assert ElvesHelpers.group_members(ElvesHelpers.recorded_pgid(goal.id, run_id)) != []
    assert ElvesHelpers.terminal_event(goal.id, run_id) == nil
    assert ElvesHelpers.count_events(goal.id, run_id, ["run.completed", "run.failed"]) == 0

    assert {:ok, event} =
             Orchestrator.record_choice(run_id, %{
               action: "wait",
               evidence_refs: packet.evidence_refs,
               rationale: "Group alive with no verdict yet; keep supervising.",
               outcome: "pending"
             })

    assert event.payload["action"] == "wait"
    assert ElvesHelpers.terminal_event(goal.id, run_id) == nil

    assert {:ok, :cancelled} = Elves.cancel_run(run_id, kill_grace_ms: 200)
  end

  test "replacement guard opens on terminal or explicit reconciliation", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    run_id = start_quiet_run(sup, goal, task, :guard_probe, [])

    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    assert {:ok, false} = Orchestrator.can_replace?(run_id)

    # Explicit reconciliation records the allowance without a terminal.
    assert {:ok, _event} =
             Orchestrator.record_choice(run_id, %{
               action: "reconcile",
               rationale: "Operator verified the orphan by hand; replacement may proceed.",
               outcome: "reconciled"
             })

    assert {:ok, true} = Orchestrator.can_replace?(run_id)
    assert {:ok, :allowed} = Orchestrator.request_replacement(run_id)

    # A terminal state also opens the guard on its own.
    assert {:ok, :cancelled} = Elves.cancel_run(run_id, kill_grace_ms: 200)
    assert {:ok, true} = Orchestrator.can_replace?(run_id)
  end

  test "record_choice validates its inputs", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    run_id = start_quiet_run(sup, goal, task, :validation_probe, [])

    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    assert {:error, {:unknown_action, "nuke"}} =
             Orchestrator.record_choice(run_id, %{action: "nuke", rationale: "x"})

    assert {:error, {:missing_rationale, _}} =
             Orchestrator.record_choice(run_id, %{action: "wait"})

    assert {:error, :run_not_found} =
             Orchestrator.record_choice(Ecto.UUID.generate(), %{action: "wait", rationale: "x"})

    assert {:ok, :cancelled} = Elves.cancel_run(run_id, kill_grace_ms: 200)
  end

  test "orchestrator carries no termination or replacement paths (pinning)" do
    source = File.read!(Path.join(File.cwd!(), "lib/shoestring/elves/orchestrator.ex"))

    for shape <- @forbidden_shapes do
      refute String.contains?(source, shape),
             "expected orchestrator.ex to contain no #{inspect(shape)} (seam records, never acts)"
    end
  end
end
