defmodule Shoestring.Harness.EvalMatrix.DemoTest do
  @moduledoc """
  Hermetic scripted demo (T6): submit → admission evidence + lease grant →
  partial work → injected exhaustion → deterministic checkpoint →
  restart-while-sleeping → wake-after-simulated-reset (fresh recheck, then a
  provider switch) → continue sans first transcript → terminal projection.

  Eight steps, two Fake adapter legs (first leg `sudden_quota_refusal`, second
  leg `handoff_target`), two request logs, FixedClock. No provider CLI, no
  network, no production code in this file.

  Locking note (standing contract): on the base commit (`c3779f0`) with the
  T6 files removed this file errors on the missing
  `Shoestring.Test.EvalMatrixHelpers` driver — documentation, not a
  behavior-change lock.
  """
  use Shoestring.DataCase, async: false

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers

  alias Oban.Job
  alias Shoestring.Cobbler.{Dispatcher, Wakeups}

  alias Shoestring.Harness.{
    CheckpointFallback,
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
    assert Repo.aggregate(Job, :count, :id) == 0

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

    assert {:ok, %{run: new_run}} =
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

    # Step 8 — terminal projection: the switched leg completes and every
    # decision remains explainable from persisted inputs.
    Eval.append_event!(goal.id, new_run.id, "run.starting", %{"run_id" => new_run.id})

    Eval.append_event!(goal.id, new_run.id, "run.running", %{
      "run_id" => new_run.id,
      "provider_session_id" => "fake-session-handoff-b"
    })

    Eval.append_event!(goal.id, new_run.id, "run.completed", %{"run_id" => new_run.id})
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
