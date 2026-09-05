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
    # rationale, action, and outcome — and the run is untouched. The
    # decision id is derived from the observation it responds to, so a
    # retry or restart deduplicates instead of duplicating.
    decision_id =
      Orchestrator.decision_id(run_id, "request_status", List.first(packet.evidence_refs))

    assert {:ok, event} =
             Orchestrator.record_choice(run_id, %{
               action: "request_status",
               decision_id: decision_id,
               evidence_refs: packet.evidence_refs,
               rationale:
                 "Test command recorded as passed; asking the child for its final report.",
               outcome: "pending"
             })

    assert event.type == "elf.recovery_decided"
    assert event.payload["action"] == "request_status"
    assert event.payload["decision_id"] == decision_id
    assert event.payload["evidence_refs"] == packet.evidence_refs
    assert event.payload["outcome"] == "pending"

    # Recording the same decision again deduplicates idempotently.
    assert {:ok, retry_event} =
             Orchestrator.record_choice(run_id, %{
               action: "request_status",
               decision_id: decision_id,
               evidence_refs: packet.evidence_refs,
               rationale:
                 "Test command recorded as passed; asking the child for its final report.",
               outcome: "pending"
             })

    assert retry_event.id == event.id

    # A replace decision over the still-active run is refused, not recorded.
    assert {:error, :prior_run_active} =
             Orchestrator.record_choice(run_id, %{
               action: "replace",
               decision_id: Orchestrator.decision_id(run_id, "replace", "obs-replace"),
               rationale: "Attempting replacement while the prior run is still active.",
               outcome: "pending"
             })

    # Nothing auto-killed or auto-replaced: Elf and group alive, no terminal,
    # replacement still refused.
    assert Elves.whereis(run_id) != nil
    assert ElvesHelpers.group_members(ElvesHelpers.recorded_pgid(goal.id, run_id)) != []
    assert ElvesHelpers.terminal_event(goal.id, run_id) == nil
    assert {:ok, false} = Orchestrator.can_replace?(run_id)

    assert {:error, :prior_run_active} =
             Orchestrator.request_replacement(run_id, decision_id: "dec-replace-live")

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
               decision_id:
                 Orchestrator.decision_id(run_id, "wait", List.first(packet.evidence_refs)),
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
               decision_id:
                 Orchestrator.decision_id(run_id, "reconcile", nil, "operator-reconciliation"),
               rationale: "Operator verified the orphan by hand; replacement may proceed.",
               outcome: "reconciled"
             })

    assert {:ok, true} = Orchestrator.can_replace?(run_id)

    assert {:ok, :allowed, _claim_id} =
             Orchestrator.request_replacement(run_id,
               decision_id: Orchestrator.decision_id(run_id, "replace", "claim-1")
             )

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
             Orchestrator.record_choice(run_id, %{
               action: "nuke",
               decision_id: "dec-1",
               rationale: "x"
             })

    assert {:error, {:missing_rationale, _}} =
             Orchestrator.record_choice(run_id, %{action: "wait", decision_id: "dec-1"})

    assert {:error, {:missing_decision_id, _}} =
             Orchestrator.record_choice(run_id, %{action: "wait", rationale: "x"})

    assert {:error, :run_not_found} =
             Orchestrator.record_choice(Ecto.UUID.generate(), %{
               action: "wait",
               decision_id: "dec-1",
               rationale: "x"
             })

    assert {:ok, :cancelled} = Elves.cancel_run(run_id, kill_grace_ms: 200)
  end

  test "decision ids are stable for identical inputs" do
    run_id = Ecto.UUID.generate()

    assert Orchestrator.decision_id(run_id, "wait", "obs-1") ==
             Orchestrator.decision_id(run_id, "wait", "obs-1")

    refute Orchestrator.decision_id(run_id, "wait", "obs-1") ==
             Orchestrator.decision_id(run_id, "wait", "obs-2")

    refute Orchestrator.decision_id(run_id, "wait", "obs-1") ==
             Orchestrator.decision_id(run_id, "escalate", "obs-1")

    # The full digest is kept: no truncation into birthday-bound territory.
    assert Orchestrator.decision_id(run_id, "wait", "obs-1") |> String.length() == 64

    # Nil is not a literal sentinel, and delimiters cannot move a value into
    # a neighboring component.
    refute Orchestrator.decision_id(run_id, "wait", "none", "token-a") ==
             Orchestrator.decision_id(run_id, "wait", nil, "token-a")

    refute Orchestrator.decision_id(run_id, "wait", "obs:alpha", "beta") ==
             Orchestrator.decision_id(run_id, "wait", "obs", "alpha:beta")

    refute Orchestrator.decision_id(run_id, "wait", "obs:none", nil) ==
             Orchestrator.decision_id(run_id, "wait", "obs", "none")
  end

  test "nil observations do not collapse distinct decisions", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    run_id = start_quiet_run(sup, goal, task, :nil_obs_probe, [])

    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    # Two genuinely different unobserved decisions for the same run and
    # action must never share an idempotency key.
    first = Orchestrator.decision_id(run_id, "wait", nil, "heartbeat-still-quiet")
    second = Orchestrator.decision_id(run_id, "wait", nil, "awaiting-approval-resolution")
    refute first == second

    assert {:ok, first_event} =
             Orchestrator.record_choice(run_id, %{
               action: "wait",
               decision_id: first,
               rationale: "Heartbeat still quiet; keep supervising."
             })

    # The second decision persists as its own event — it is not swallowed
    # as a duplicate of the first.
    assert {:ok, second_event} =
             Orchestrator.record_choice(run_id, %{
               action: "wait",
               decision_id: second,
               rationale: "Awaiting approval resolution; keep supervising."
             })

    refute second_event.id == first_event.id

    assert ElvesHelpers.count_events(goal.id, run_id, ["elf.recovery_decided"]) == 2

    assert {:ok, :cancelled} = Elves.cancel_run(run_id, kill_grace_ms: 200)
  end

  test "decision_id raises ArgumentError when unobserved and discriminator is missing" do
    run_id = Ecto.UUID.generate()

    assert_raise ArgumentError, fn ->
      Orchestrator.decision_id(run_id, "wait")
    end

    assert_raise ArgumentError, fn ->
      Orchestrator.decision_id(run_id, "reconcile", nil)
    end

    assert_raise ArgumentError, fn ->
      Orchestrator.decision_id(run_id, "reconcile", nil, "")
    end
  end

  test "ten concurrent replacement rivals assert different attempts and grant one winner", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    run_id = start_quiet_run(sup, goal, task, :claim_race_probe, [])

    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    assert {:ok, :cancelled} = Elves.cancel_run(run_id, kill_grace_ms: 200)
    assert {:ok, true} = Orchestrator.can_replace?(run_id)

    # An Oban retry racing the orchestrator loop: ten distinct decisions
    # claim at once, and exactly one may dispatch a replacement.
    tasks =
      for n <- 1..10 do
        Task.async(fn ->
          receive do
            :start ->
              {n,
               Orchestrator.request_replacement(run_id,
                 decision_id: "race-decision-#{n}",
                 attempt: n
               )}
          end
        end)
      end

    for task <- tasks, do: send(task.pid, :start)
    results = Task.await_many(tasks, 30_000)

    assert Enum.map(results, &elem(&1, 0)) |> Enum.sort() == Enum.to_list(1..10)
    outcomes = Enum.map(results, &elem(&1, 1))
    assert Enum.count(outcomes, &match?({:ok, :allowed, _claim_id}, &1)) == 1
    assert Enum.count(outcomes, &(&1 == {:error, :prior_replacement_active})) == 9

    assert ElvesHelpers.replacement_claim(goal.id, run_id).payload["attempt"] == 1

    # The winner retrying with its own decision id stays allowed.
    winner_id = ElvesHelpers.replacement_claim(goal.id, run_id).payload["decision_id"]

    assert {:ok, :allowed, _claim_id} =
             Orchestrator.request_replacement(run_id, decision_id: winner_id)
  end

  test "a replacement claim blocks an interleaved rival after its append commits", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    run_id = start_quiet_run(sup, goal, task, :interleaved_probe, [])

    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    assert {:ok, :cancelled} = Elves.cancel_run(run_id, kill_grace_ms: 200)

    assert {:ok, :allowed, _claim_id} =
             Orchestrator.request_replacement(run_id, decision_id: "interleaved-winner")

    # Rival two queries only after rival one has committed its append. It
    # cannot turn the unlinked claim into a new round.
    assert {:error, :prior_replacement_active} =
             Orchestrator.request_replacement(run_id, decision_id: "interleaved-rival")
  end

  test "a caller asserted attempt cannot bypass an active replacement claim", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    run_id = start_quiet_run(sup, goal, task, :asserted_attempt_probe, [])

    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)
    assert {:ok, :cancelled} = Elves.cancel_run(run_id, kill_grace_ms: 200)

    assert {:ok, :allowed, _claim_id} =
             Orchestrator.request_replacement(run_id, decision_id: "round-1")

    # A stale caller's large assertion is informational only; it cannot
    # bypass the durable active/unlinked claim.
    assert {:error, :prior_replacement_active} =
             Orchestrator.request_replacement(run_id,
               decision_id: "asserted-stale-rival",
               attempt: 99
             )
  end

  test "an active linked replacement blocks the next round", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    run_id = start_quiet_run(sup, goal, task, :active_replacement_probe, [])

    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)
    assert {:ok, :cancelled} = Elves.cancel_run(run_id, kill_grace_ms: 200)

    assert {:ok, :allowed, claim_id} =
             Orchestrator.request_replacement(run_id, decision_id: "round-1")

    claim = ElvesHelpers.replacement_claim(goal.id, run_id)
    assert claim.id == claim_id
    replacement_id = start_quiet_run(sup, goal, task, :active_replacement_child, [])

    on_exit(fn ->
      ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, replacement_id))
    end)

    assert {:ok, link} = Orchestrator.link_replacement_claim(claim.id, replacement_id)
    assert link.run_id == replacement_id
    assert link.payload["claim_id"] == claim.id
    assert link.payload["prior_run_id"] == run_id

    assert {:ok, same_link} = Orchestrator.link_replacement_claim(claim.id, replacement_id)
    assert same_link.id == link.id

    second_replacement_id = start_quiet_run(sup, goal, task, :second_replacement_child, [])

    on_exit(fn ->
      ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, second_replacement_id))
    end)

    assert {:error, :replacement_claim_already_linked} =
             Orchestrator.link_replacement_claim(claim.id, second_replacement_id)

    assert {:error, :prior_replacement_active} =
             Orchestrator.request_replacement(run_id, decision_id: "round-2-while-active")

    assert {:ok, reconciled} = Orchestrator.reconcile_replacement_claim(claim.id)
    assert reconciled.payload["replacement_run_id"] == replacement_id

    assert {:ok, :allowed, round_two_claim_id} =
             Orchestrator.request_replacement(run_id, decision_id: "round-2-after-reconcile")

    refute round_two_claim_id == claim.id
  end

  test "omitted attempt claims the next round after the linked replacement terminalizes", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    run_id = start_quiet_run(sup, goal, task, :default_round_probe, [])

    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)
    assert {:ok, :cancelled} = Elves.cancel_run(run_id, kill_grace_ms: 200)

    assert {:ok, :allowed, _claim_id} =
             Orchestrator.request_replacement(run_id, decision_id: "round-1")

    claim = ElvesHelpers.replacement_claim(goal.id, run_id)
    replacement_id = start_quiet_run(sup, goal, task, :default_round_child, [])

    on_exit(fn ->
      ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, replacement_id))
    end)

    assert {:ok, _link} = Orchestrator.link_replacement_claim(claim.id, replacement_id)
    assert {:ok, :cancelled} = Elves.cancel_run(replacement_id, kill_grace_ms: 200)

    assert {:ok, :allowed, _claim_id} =
             Orchestrator.request_replacement(run_id, decision_id: "round-2-default")

    assert ElvesHelpers.replacement_claim(goal.id, run_id).payload["attempt"] == 2
  end

  test "rivals after terminalization derive one next round and grant one winner", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    run_id = start_quiet_run(sup, goal, task, :terminal_rivals_probe, [])

    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)
    assert {:ok, :cancelled} = Elves.cancel_run(run_id, kill_grace_ms: 200)

    assert {:ok, :allowed, _claim_id} =
             Orchestrator.request_replacement(run_id, decision_id: "round-1")

    claim = ElvesHelpers.replacement_claim(goal.id, run_id)
    replacement_id = start_quiet_run(sup, goal, task, :terminal_rivals_child, [])

    on_exit(fn ->
      ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, replacement_id))
    end)

    assert {:ok, _link} = Orchestrator.link_replacement_claim(claim.id, replacement_id)
    assert {:ok, :cancelled} = Elves.cancel_run(replacement_id, kill_grace_ms: 200)

    results =
      1..10
      |> Task.async_stream(
        fn attempt ->
          {attempt,
           Orchestrator.request_replacement(run_id,
             decision_id: "terminal-rival-#{attempt}",
             attempt: attempt + 40
           )}
        end,
        max_concurrency: 10,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.map(results, &elem(&1, 0)) |> Enum.sort() == Enum.to_list(1..10)
    assert Enum.count(results, &match?({:ok, :allowed, _claim_id}, elem(&1, 1))) == 1
    assert ElvesHelpers.replacement_claim(goal.id, run_id).payload["attempt"] == 2
  end

  test "an abandoned claim is explicitly reconciled before the next round", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    run_id = start_quiet_run(sup, goal, task, :reconcile_claim_probe, [])

    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)
    assert {:ok, :cancelled} = Elves.cancel_run(run_id, kill_grace_ms: 200)

    assert {:ok, :allowed, _claim_id} =
             Orchestrator.request_replacement(run_id, decision_id: "round-1")

    claim = ElvesHelpers.replacement_claim(goal.id, run_id)
    assert {:ok, event} = Orchestrator.reconcile_replacement_claim(claim.id)
    assert event.payload["replacement_claim_id"] == claim.id
    assert event.payload["outcome"] == "reconciled"

    assert {:ok, :allowed, _claim_id} =
             Orchestrator.request_replacement(run_id, decision_id: "round-2-after-reconcile")

    assert ElvesHelpers.replacement_claim(goal.id, run_id).payload["attempt"] == 2
  end

  test "the default attempt is not a gate after explicit claim reconciliation", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    run_id = start_quiet_run(sup, goal, task, :default_reconciled_probe, [])

    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)
    assert {:ok, :cancelled} = Elves.cancel_run(run_id, kill_grace_ms: 200)

    assert {:ok, :allowed, _claim_id} =
             Orchestrator.request_replacement(run_id, decision_id: "round-1")

    claim = ElvesHelpers.replacement_claim(goal.id, run_id)

    assert {:ok, _event} =
             Orchestrator.record_choice(run_id, %{
               action: "reconcile",
               decision_id: "reconcile-round-1",
               replacement_claim_id: claim.id,
               rationale: "Operator reconciled the abandoned replacement claim.",
               outcome: "reconciled"
             })

    assert {:ok, :allowed, _claim_id} =
             Orchestrator.request_replacement(run_id, decision_id: "round-2-default")
  end

  test "orchestrator carries no termination or replacement paths (pinning)" do
    source = File.read!(Path.join(File.cwd!(), "lib/shoestring/elves/orchestrator.ex"))

    for shape <- @forbidden_shapes do
      refute String.contains?(source, shape),
             "expected orchestrator.ex to contain no #{inspect(shape)} (seam records, never acts)"
    end
  end
end
