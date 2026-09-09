defmodule Shoestring.Harness.EvalMatrix.AblationTest do
  @moduledoc """
  Genuine semantic ablation (T6, loop-closure I7): four arms on one scripted
  fixture task (inspect relevant+irrelevant files, record constraint + rejected
  approach, partial implement, failing test, scripted refusal).

  The milestone's three input arms — worktree-only, naive-summary, and
  trajectory-projection — differ ONLY in the checkpoint `next_action` Elf B
  receives; the fourth arm is the retained deterministic fallback template
  (prior authored-vs-fallback result must reproduce: byte-equal normalized
  terminal state). Every arm: Fake fixture leg + quota refusal → genuine
  checkpoint writer → projection → `Continuation.for_goal/1` (what Elf B
  receives — never the transcript) → `Elves.resume_run/3` handoff →
  leg-B Fake stream (`handoff_target` RESULT) consumed by a real supervised
  Elf bound through the durable dispatch pipeline → `run.completed` arrives
  through the Elf's production commit path, never via a hand-appended insert
  in this file.

  Scoring follows the milestone rubric with the harness-synthesized
  deterministic normalization documented in
  `Shoestring.Test.EvalMatrixHelpers` and
  `plans/evidence/05-quota-aware-mvp/ablation.md`; turns-to-progress and
  capacity consumed are recorded as genuine handoff-tax metrics per arm.

  Hermetic: Fake scenarios, FixedClock, synthetic identifiers only. No
  provider CLI, no network, no production code in this file.

  Locking note (standing contract): on the base commit (`cc116f4`) with the
  I7 driver removed this file errors on the missing
  `Shoestring.Test.EvalMatrixHelpers` driver — documentation, not a
  behavior-change lock. I7 ships no producer, so with the driver present these
  tests document wired loop behavior honestly rather than locking a behavior
  change.
  """
  use Shoestring.DataCase, async: false

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers

  alias Shoestring.Harness.{
    Checkpoint,
    CheckpointFallback,
    Checkpoints,
    Continuation,
    Fake,
    Projector,
    RunRecord
  }

  alias Shoestring.Harness.Fake.{RequestLog, Scenario}
  alias Shoestring.Test.EvalMatrixHelpers, as: Eval
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Trajectory.TrajectoryEvent

  @session "fake-session-resume"

  @arms [:worktree_only, :naive_summary, :trajectory_projection, :fallback_template]

  test "four arms complete genuinely; trajectory projection carries context at the lowest tax" do
    sup = start_supervised!({Shoestring.Elves.Supervisor, name: nil})
    results = Map.new(@arms, fn mode -> {mode, run_arm(mode, sup)} end)

    # Every arm reaches `run.completed` through resumed Elf execution with a
    # green privacy sweep.
    for mode <- @arms do
      assert results[mode].terminal_class == :completed
      assert results[mode].new_run_status == "completed"
      assert results[mode].privacy_scan == []
      assert results[mode].privacy_safe?
    end

    # No hand-appended lifecycle event on any driven leg-B path.
    for mode <- @arms do
      refute "eval-matrix" in results[mode].leg_b_actors
      assert "elf" in results[mode].leg_b_actors
    end

    # P3: the prior fallback-vs-authored result reproduces — the normalized
    # terminal projection state is byte-comparable between the intact
    # (trajectory-projection) arm and the fallback arm.
    assert results[:trajectory_projection].next_action != results[:fallback_template].next_action
    assert byte_size(results[:fallback_template].next_action) > 0

    assert :erlang.term_to_binary(results[:trajectory_projection].normalized) ==
             :erlang.term_to_binary(results[:fallback_template].normalized)

    # The trajectory-projection arm carries the constraint crisply at the
    # lowest handoff tax, so it outscores every other arm.
    trajectory = results[:trajectory_projection].scores

    for mode <- [:worktree_only, :naive_summary, :fallback_template] do
      assert trajectory.total > results[mode].scores.total,
             "#{mode} unexpectedly matched the trajectory-projection total"
    end

    assert trajectory.constraint == 2
    assert results[:worktree_only].scores.constraint == 0
    assert results[:fallback_template].scores.constraint == 0
    assert results[:naive_summary].scores.constraint == 1

    # Handoff tax is genuine and bounded: exactly one fresh start, zero
    # resumes, and a fixed scripted turn count on every arm.
    for mode <- @arms do
      tax = results[mode].tax
      assert tax.adapter_starts == 1
      assert tax.adapter_resumes == 0
      assert tax.harness_events == 3
    end

    assert results[:trajectory_projection].prompt_bytes <
             results[:naive_summary].prompt_bytes
  end

  # ----------------------------------------------------------------------------
  # Arm driver (one scripted fixture task; arms differ ONLY in next_action)
  # ----------------------------------------------------------------------------

  defp run_arm(mode, sup) do
    goal = FakeHelpers.insert_goal(Ecto.UUID.generate())
    task = FakeHelpers.insert_task(goal, Ecto.UUID.generate())

    run =
      FakeHelpers.insert_run_record(goal, task, Ecto.UUID.generate(),
        run_id: Ecto.UUID.generate()
      )

    decision_id = Ecto.UUID.generate()
    checkpoint_id = Ecto.UUID.generate()

    # Setup history seeding (not the driven path): admission evidence for the
    # decision refs the handoff must carry.
    append_admission_event!(goal.id, admission_payload(decision_id: decision_id))

    # Leg A through the real adapter leg: scripted fixture work, then the
    # quota refusal terminal.
    {:ok, events} =
      Fake.stream(
        %Shoestring.Harness.RunIdentity{
          run_id: run.id,
          harness_id: "shoestring.harness.fake",
          process_id: "fake-pid-eval",
          provider_session_id: @session
        },
        %{scenario: Eval.fixture_leg_scenario(), clock: Shoestring.Test.FixedClock}
      )

    assert Enum.map(events, & &1.kind) == [
             :lifecycle,
             :output,
             :output,
             :output,
             :error
           ]

    refusal = List.last(events)
    assert refusal.error.category == :quota_refused

    # Checkpoint through the genuine writer with the arm's next_action input.
    checkpoint = arm_checkpoint!(mode, goal.id, run.id, checkpoint_id)

    assert {:ok, %{outcome: :recorded}} = Checkpoints.record(goal.id, checkpoint)
    assert {:ok, _} = Projector.project(goal.id, clock: Shoestring.Test.FixedClock)

    # Checkpoint projection only (what Elf B receives): never the transcript.
    assert {:ok, continuation} = Continuation.for_goal(goal.id)
    assert continuation.checkpoint_id == checkpoint_id
    assert continuation.next_action == checkpoint.next_action

    {:ok, log} = RequestLog.start()
    new_run_id = Ecto.UUID.generate()

    assert {:ok, %{run: new_run}} =
             Shoestring.Elves.resume_run(run.id,
               adapter: Fake,
               adapter_opts: Eval.adapter_opts(log, Scenario.handoff_target()),
               continuation: %{
                 checkpoint_id: checkpoint_id,
                 next_action: checkpoint.next_action,
                 decision_refs: [decision_id]
               },
               provider_session_id: @session,
               to_provider_id: "fake-harness-b",
               reason: "quota handoff",
               new_run_id: new_run_id,
               new_dispatch_id: Ecto.UUID.generate()
             )

    # I5 handoff evidence (genuine): the cross-provider transfer started a
    # FRESH session via adapter.start/2, never resume, carrying pointer keys
    # only.
    [recorded] = RequestLog.starts(log)
    assert RequestLog.resumes(log) == []

    recorded_continuation =
      Map.new(recorded.continuation, fn {k, v} -> {to_string(k), v} end)

    assert Enum.sort(Map.keys(recorded_continuation)) == [
             "checkpoint_id",
             "decision_refs",
             "next_action"
           ]

    scan = Shoestring.Harness.Security.scan_term(recorded_continuation)

    # Leg B through resumed execution: a real supervised Elf bound to the
    # handoff run consumes the `handoff_target` RESULT stream and commits
    # `run.completed` through its production path.
    leg_b_run = Repo.get!(RunRecord, new_run.id)

    %{terminal: terminal} =
      Eval.drive_leg_to_terminal!(leg_b_run,
        scenario: Scenario.handoff_target(),
        supervisor: sup
      )

    assert terminal.class == :completed

    # I3 terminal checkpoint before the terminal, via the Elf's production
    # path — on every arm.
    completed_event =
      Repo.one!(
        from event in TrajectoryEvent,
          where:
            event.goal_id == ^goal.id and event.run_id == ^new_run.id and
              event.type == "run.completed",
          order_by: [desc: event.sequence],
          limit: 1
      )

    terminal_checkpoint =
      Repo.one!(
        from event in TrajectoryEvent,
          where:
            event.goal_id == ^goal.id and event.run_id == ^new_run.id and
              event.type == "checkpoint.created",
          order_by: [asc: event.sequence],
          limit: 1
      )

    assert terminal_checkpoint.sequence < completed_event.sequence

    assert terminal_checkpoint.payload["extensions"]["shoestring.elf:checkpoint_kind"] ==
             "terminal"

    assert {:ok, _} = Projector.project(goal.id, clock: Shoestring.Test.FixedClock)

    new_status = Repo.get!(RunRecord, new_run.id).status

    handoff_event =
      Repo.one!(
        from event in TrajectoryEvent,
          where: event.goal_id == ^goal.id and event.type == "handoff.created",
          order_by: [desc: event.sequence],
          limit: 1
      )

    tax = Eval.leg_tax(goal.id, new_run.id, log)
    prompt = recorded.prompt

    scores =
      Eval.score_arm(%{
        terminal_class: terminal.class,
        prompt: prompt,
        next_action: checkpoint.next_action,
        decision_ref_count: length(handoff_event.payload["decision_refs"]),
        leg_b_event_count: tax.harness_events,
        starts: tax.adapter_starts,
        resumes: tax.adapter_resumes
      })

    %{
      mode: mode,
      next_action: checkpoint.next_action,
      terminal_class: terminal.class,
      new_run_status: new_status,
      privacy_scan: scan,
      privacy_safe?: Shoestring.Harness.Contract.safe_term?(recorded_continuation),
      leg_b_actors: tax.actors,
      tax: tax,
      prompt_bytes: byte_size(prompt),
      scores: scores,
      normalized: %{
        run_status: new_status,
        decision_ref_count: length(handoff_event.payload["decision_refs"]),
        reason: handoff_event.payload["reason"],
        to_provider: handoff_event.payload["to_provider_id"],
        next_action_present?: byte_size(checkpoint.next_action) > 0,
        stop: "quota_refused"
      }
    }
  end

  defp arm_checkpoint!(:fallback_template, goal_id, run_id, checkpoint_id) do
    {:ok, template} =
      CheckpointFallback.build(%{
        checkpoint_id: checkpoint_id,
        goal_id: goal_id,
        run_id: run_id,
        acceptance_criteria: ["fixture suite passes"],
        repository_revision: "abc123",
        stop_reason: "quota_refused"
      })

    template
  end

  defp arm_checkpoint!(mode, goal_id, run_id, checkpoint_id) do
    {:ok, checkpoint} =
      Checkpoint.new(%{
        version: 1,
        checkpoint_id: checkpoint_id,
        goal_id: goal_id,
        run_id: run_id,
        acceptance_contract: %{criteria: ["fixture suite passes"]},
        repository_state: %{revision: "abc123", dirty: false},
        evidence: [
          "inspected lib/widget.ex (relevant) and lib/unrelated.ex (irrelevant)",
          "recorded constraint: five-hour reserve",
          "rejected approach B: in-memory cache (violates the reserve)",
          "partial implement: widget steps 1-2",
          "failing test: WidgetTest second case"
        ],
        decisions: ["chose approach A", "rejected approach B: in-memory cache"],
        unresolved_issues: ["WidgetTest second case still failing"],
        next_action: Eval.arm_next_action(mode),
        provider_session_id: @session,
        stop_reason: "quota_refused",
        artifact_ids: [],
        extensions: %{}
      })

    checkpoint
  end
end
