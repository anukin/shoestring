defmodule Shoestring.Harness.EvalMatrix.DemoTest do
  @moduledoc """
  Hermetic scripted demo (T6, loop-closure I7): submit → admission evidence +
  lease grant → partial work → injected exhaustion → deterministic checkpoint →
  restart-while-sleeping → wake-after-simulated-reset (fresh recheck, then a
  provider switch) → continue sans first transcript → terminal projection
  through resumed execution.

  Eight steps, two Fake adapter legs (first leg `sudden_quota_refusal`, second
  leg `handoff_target`), two request logs, FixedClock. Steps 1–7 drive the
  guarded dispatch pipeline (I1), the lease loop (I2), the fallback checkpoint
  (I3 writer), the admitted wake→dispatch (I4), and the intent-first
  fresh-session handoff with composed prompt (I5). Step 8 drives leg B to
  `run.completed` through a real supervised Elf bound to the handoff run via
  the durable dispatch pipeline — the terminal arrives through the Elf's
  production commit path (plus the I3 terminal checkpoint), never via a
  hand-appended insert in this file. No provider CLI, no network, no
  production code in this file.

  Locking note (standing contract): on the base commit (`cc116f4`) with the
  I7 driver (`Shoestring.Test.EvalMatrixHelpers.drive_leg_to_terminal!/2`)
  removed this file errors on the missing driver — documentation, not a
  behavior-change lock. I7 ships no producer, so with the driver present these
  tests document wired loop behavior honestly rather than locking a behavior
  change.
  """
  use Shoestring.DataCase, async: false

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers

  alias Oban.Job
  alias Shoestring.Cobbler.{Dispatcher, Wakeups}
  alias Shoestring.Elves

  alias Shoestring.Harness.{
    CheckpointFallback,
    CheckpointRecord,
    Checkpoints,
    Continuation,
    ExecutionLeaseRecord,
    Fake,
    Projector,
    RunRecord
  }

  alias Shoestring.Harness.Fake.{RequestLog, Scenario}
  alias Shoestring.Test.EvalMatrixHelpers, as: Eval
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Trajectory.TrajectoryEvent

  @now ~U[2026-09-07 12:00:00.000000Z]
  @session "fake-session-demo-a"
  @first_transcript_text "partial work on the widget"

  test "scripted quota-aware demo completes across exhaustion, reset, and provider switch" do
    # Step 1 — submit: goal + task + admission evidence.
    goal = create_goal!(Repo, "Eval demo goal")
    task = Eval.insert_task!(goal)
    snapshot_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, snapshot_id)

    admission =
      append_admission_event!(
        goal.id,
        Eval.grant_payload(snapshot_id, "admit", "automatic_admission_eligible")
      )

    assert admission.payload["result"] == "admit"

    # Step 2 — lease grant: claim through the gated dispatcher.
    command = claim_command(admission, command_id: "cmd-eval-demo-claim")

    assert {:ok, leased} =
             Dispatcher.claim_and_gate(goal.id, command,
               now: @now,
               grant_lease: [task_id: task.id, clock: Shoestring.Test.FixedClock, now: @now]
             )

    run = leased.run
    grant_id = leased.grant_id

    # P1 durable delivery: the grant is persisted first, then exactly one
    # dispatch job is enqueued (dispatch record + Oban job, never a direct
    # spawn). The run row stays `requested` until the worker delivers it.
    assert Repo.aggregate(Job, :count, :id) == 1
    assert leased.dispatch.run_id == run.id
    assert leased.job.args["dispatch_id"] == leased.dispatch.dispatch_id

    # Step 3 — partial work on the first Fake leg (its own request log).
    {:ok, log_a} = RequestLog.start()

    {:ok, events} =
      Fake.stream(
        %Shoestring.Harness.RunIdentity{
          run_id: run.id,
          harness_id: "shoestring.harness.fake",
          process_id: "fake-pid-eval",
          provider_session_id: @session
        },
        %{
          scenario: Scenario.sudden_quota_refusal(),
          clock: Shoestring.Test.FixedClock,
          request_log: log_a
        }
      )

    assert Enum.map(events, & &1.kind) == [:lifecycle, :output, :error]
    assert hd(events).kind == :lifecycle

    # Step 4 — injected exhaustion: the provider reports quota refusal.
    refusal = List.last(events)
    assert refusal.error.category == :quota_refused
    assert refusal.error.code == "rate_limit_exceeded"

    # Step 5 — deterministic checkpoint via the no-model fallback.
    {:ok, checkpoint} =
      CheckpointFallback.build(%{
        checkpoint_id: Ecto.UUID.generate(),
        goal_id: goal.id,
        run_id: run.id,
        acceptance_criteria: ["tests pass"],
        repository_revision: "abc123",
        stop_reason: "quota_refused"
      })

    assert {:ok, %{outcome: :recorded, checkpoint_id: checkpoint_id}} =
             Checkpoints.record(goal.id, checkpoint)

    assert {:ok, _} = Projector.project(goal.id, clock: Shoestring.Test.FixedClock)
    assert {:ok, continuation} = Continuation.for_goal(goal.id)
    assert continuation.checkpoint_id == checkpoint_id

    # Step 6 — restart-while-sleeping: suspend, schedule, reboot the
    # reconciler (two passes converge on exactly one wakeup job).
    Eval.suspend_run!(goal.id, run.id, @now)
    assert {:ok, _} = Projector.project(goal.id, clock: Shoestring.Test.FixedClock)
    wakeup = Eval.schedule_wake!(goal, run, "cmd-eval-demo-wake", @now)

    assert {:ok, %{failures: []}} = Wakeups.reconcile(now: @now)
    assert {:ok, %{repaired_count: 0, failures: []}} = Wakeups.reconcile(now: @now)

    assert Repo.aggregate(
             from(job in Job,
               where:
                 job.queue == "wakeup" and
                   fragment("json_extract(?, '$.wakeup_id') = ?", job.args, ^wakeup.id)
             ),
             :count,
             :id
           ) == 1

    # Step 7 — wake-after-simulated-reset with a FRESH snapshot, then switch
    # provider: the fresh recheck renews + resumes, and the handoff to the
    # second Fake leg carries only the checkpoint pointer.
    fresh = Eval.eligible_snapshot(@now)
    refute fresh.snapshot_id == snapshot_id

    assert {:ok, summary} =
             Wakeups.perform_wakeup(wakeup.id,
               now: @now,
               clock: Shoestring.Test.FixedClock,
               observe: fn -> {:ok, fresh} end
             )

    assert summary.branch == :admitted
    assert summary.lease == :renewed
    assert Repo.get!(ExecutionLeaseRecord, grant_id).admitted_snapshot_id == fresh.snapshot_id

    {:ok, log_b} = RequestLog.start()
    new_run_id = Ecto.UUID.generate()
    decision_id = admission.payload["decision_id"]

    # The wake persisted a newer admission decision above, so the pre-wake
    # triple is genuinely stale and must be refused (not silently reused).
    assert {:error, :decision_superseded} =
             Shoestring.Elves.resume_run(run.id,
               adapter: Fake,
               adapter_opts: Eval.adapter_opts(log_b, Scenario.handoff_target()),
               continuation: %{
                 checkpoint_id: checkpoint_id,
                 next_action: continuation.next_action,
                 decision_refs: [decision_id]
               },
               provider_session_id: @session,
               to_provider_id: "fake-harness-b",
               reason: "quota handoff",
               new_run_id: Ecto.UUID.generate(),
               new_dispatch_id: Ecto.UUID.generate()
             )

    # Re-project after the wake: the fresh triple carries the wake decision.
    assert {:ok, fresh_cont} = Continuation.for_goal(goal.id)
    assert fresh_cont.checkpoint_id == checkpoint_id
    refute fresh_cont.decision_refs == [decision_id]

    assert {:ok, %{run: new_run}} =
             Shoestring.Elves.resume_run(run.id,
               adapter: Fake,
               adapter_opts: Eval.adapter_opts(log_b, Scenario.handoff_target()),
               continuation: %{
                 checkpoint_id: checkpoint_id,
                 next_action: fresh_cont.next_action,
                 decision_refs: fresh_cont.decision_refs
               },
               provider_session_id: @session,
               to_provider_id: "fake-harness-b",
               reason: "quota handoff",
               new_run_id: new_run_id,
               new_dispatch_id: Ecto.UUID.generate()
             )

    # Continue sans first transcript: the second leg received pointer keys
    # only, and the first leg's transcript text traveled nowhere.
    # I5 handoff correction (P2): cross-provider transfer starts a FRESH
    # session via adapter.start/2, never resume.
    [recorded] = RequestLog.starts(log_b)
    assert RequestLog.resumes(log_b) == []

    assert Enum.sort(Map.keys(recorded.continuation)) == [
             :checkpoint_id,
             :decision_refs,
             :next_action
           ]

    refute inspect(recorded.continuation) =~ @first_transcript_text
    assert recorded.prompt != @first_transcript_text

    # Step 8 — terminal projection through resumed execution: leg B runs to
    # completion under a real supervised Elf bound to the handoff run through
    # the durable dispatch pipeline. run.starting / run.running / run.completed
    # arrive via the Elf's production commit path (plus the I3 terminal
    # checkpoint) — no hand-appended terminal insert exists on this path.
    leg_b_run = Repo.get!(RunRecord, new_run.id)

    assert {:ok, handoff_request} = Elves.request_from_run(leg_b_run)

    # The recorded prompt is exactly what the production handoff path
    # composes from the fresh triple plus the checkpoint record (sections
    # included) — reconstructed here with the same inputs.
    record = Repo.get!(CheckpointRecord, checkpoint_id)

    assert handoff_request.prompt ==
             Continuation.compose_handoff_prompt(
               %{
                 checkpoint_id: fresh_cont.checkpoint_id,
                 next_action: fresh_cont.next_action,
                 decision_refs: fresh_cont.decision_refs
               },
               checkpoint_record: record
             )

    refute handoff_request.prompt =~ @first_transcript_text

    %{dispatch: dispatch_b, terminal: terminal} =
      Eval.drive_leg_to_terminal!(leg_b_run, scenario: Scenario.handoff_target())

    assert terminal.class == :completed

    # No hand-appended events on the driven path: every leg-B lifecycle event
    # carries a production actor (the eval-matrix actor appears nowhere for
    # the handoff run), and the terminal bears the Elf's durable key.
    leg_b_actors =
      Repo.all(
        from event in TrajectoryEvent,
          where: event.goal_id == ^goal.id and event.run_id == ^new_run.id,
          select: event.actor
      )

    refute "eval-matrix" in leg_b_actors
    assert "elf" in leg_b_actors

    assert Repo.one!(
             from event in TrajectoryEvent,
               where:
                 event.goal_id == ^goal.id and event.run_id == ^new_run.id and
                   event.type == "run.completed" and
                   event.idempotency_key == ^"elf-terminal:#{dispatch_b.dispatch_id}"
           )

    # I3 terminal checkpoint: the Elf recorded repo-evidence checkpoint
    # contents BEFORE the terminal commit through its production path.
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

    assert Repo.get!(RunRecord, new_run.id).status == "completed"

    handoff_event =
      Repo.one!(
        from event in TrajectoryEvent,
          where: event.goal_id == ^goal.id and event.type == "handoff.created",
          order_by: [desc: event.sequence],
          limit: 1
      )

    assert handoff_event.payload["checkpoint_id"] == checkpoint_id
    assert handoff_event.payload["prior_run_id"] == run.id
    assert handoff_event.payload["to_provider_id"] == "fake-harness-b"
  end
end
