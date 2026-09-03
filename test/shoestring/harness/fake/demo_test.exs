defmodule Shoestring.Harness.Fake.DemoTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.Harness.{
    CapacitySnapshot,
    CapacitySnapshotRecord,
    Checkpoint,
    CheckpointRecord,
    EventPayload,
    ExecutionLease,
    ExecutionLeaseRecord,
    Fake,
    Projector,
    RunIdentity,
    RunRecord,
    Runs
  }

  alias Shoestring.Harness.Fake.{RequestLog, Scenario}
  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.Task
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Test.FixedClock

  @moduledoc """
  End-to-end automated integration test for the single scripted 7-step goal demo
  mandated by plans/milestones/02-harness-contracts-fake.md lines 191-204.

  Exercises one coherent goal lifecycle across:
  1. Healthy capacity observation and ExecutionLease grant;
  2. Partial work events from Fake Adapter A;
  3. Sudden quota refusal before an end-of-turn response;
  4. Deterministic Checkpoint creation without model inference;
  5. Simulated application restart plus trajectory replay and projection reconstruction;
  6. Continuation through Fake Adapter B using only structured checkpoint state,
     verifying zero raw transcript leakage;
  7. Verified terminal completion.
  """

  @fixed_now ~U[2026-09-02 12:00:00.000000Z]
  @snapshot_id_a "00000000-0000-4000-8000-000000000a01"
  @snapshot_id_b "00000000-0000-4000-8000-000000000a02"
  @dispatch_id_a "00000000-0000-4000-8000-000000000d01"
  @dispatch_id_b "00000000-0000-4000-8000-000000000d02"
  @grant_id_a "00000000-0000-4000-8000-000000000e01"
  @grant_id_b "00000000-0000-4000-8000-000000000e02"
  @checkpoint_id "00000000-0000-4000-8000-000000000c01"

  test "unified 7-step goal demo executes full offline recovery and handoff lifecycle" do
    # Supervised process startup following AGENTS.md
    log_a =
      start_supervised!(%{
        id: :demo_request_log_a,
        start: {RequestLog, :start_link, [[]]}
      })

    log_b =
      start_supervised!(%{
        id: :demo_request_log_b,
        start: {RequestLog, :start_link, [[]]}
      })

    # Initialize a coherent goal and task
    goal_id = "00000000-0000-4000-8000-000000000001"
    task_id = "00000000-0000-4000-8000-000000000002"
    goal = FakeHelpers.insert_goal(goal_id)
    task = FakeHelpers.insert_task(goal, task_id)

    assert {:ok, _} =
             Trajectory.append(goal.id, %{
               "type" => "goal.created",
               "schema_version" => 1,
               "actor" => "test",
               "occurred_at" => @fixed_now,
               "payload" => %{"title" => goal.title}
             })

    assert {:ok, _} =
             Trajectory.append(
               goal.id,
               %{
                 "type" => "task.created",
                 "schema_version" => 1,
                 "actor" => "test",
                 "occurred_at" => @fixed_now,
                 "payload" => %{"task_id" => task.id, "title" => task.title}
               },
               trusted: [task_id: task.id]
             )

    # -------------------------------------------------------------------------
    # Step 1: Healthy capacity observation and ExecutionLease grant
    # -------------------------------------------------------------------------
    scenario_a = Scenario.sudden_quota_refusal(snapshot_id: @snapshot_id_a, now: @fixed_now)
    opts_a = %{scenario: scenario_a, clock: FixedClock, request_log: log_a}

    assert {:ok, snapshot_a} = Fake.probe(opts_a)
    assert snapshot_a.version == 2
    assert snapshot_a.capacity_state == :observed
    assert snapshot_a.confidence == :high
    assert snapshot_a.support_tier == :proactive
    assert snapshot_a.compatibility_state == :compatible
    assert CapacitySnapshot.eligible?(snapshot_a, @fixed_now)

    assert {:ok, _snap_event} =
             Trajectory.append(goal.id, %{
               "type" => "capacity.snapshot_observed",
               "schema_version" => 2,
               "actor" => "harness",
               "occurred_at" => @fixed_now,
               "idempotency_key" => "cap-obs-#{@snapshot_id_a}",
               "payload" => EventPayload.capacity_snapshot(snapshot_a)
             })

    request_a =
      FakeHelpers.make_run_request(goal, task, @dispatch_id_a,
        prompt: "Analyze repository layout and formulate milestone implementation plan"
      )

    assert {:ok, run_a} =
             Runs.request(request_a, Fake.identity(),
               clock: FixedClock,
               identifier: Shoestring.Harness.SystemIdentifier
             )

    assert run_a.status == "requested"
    assert run_a.goal_id == goal.id
    assert run_a.task_id == task.id
    assert run_a.dispatch_id == @dispatch_id_a

    deadline_a = DateTime.add(@fixed_now, 1800, :second)

    assert {:ok, lease_a} =
             ExecutionLease.new(%{
               version: 1,
               grant_id: @grant_id_a,
               run_id: run_a.id,
               admitted_snapshot_id: snapshot_a.snapshot_id,
               reserves: %{response: 2, tool: 5},
               response_budget: 10,
               tool_budget: 20,
               deadline: deadline_a,
               checkpoint_cadence: 5,
               renewal_state: :none,
               extensions: %{}
             })

    assert {:ok, _} =
             Trajectory.append(
               goal.id,
               %{
                 "type" => "lease.proposed",
                 "schema_version" => 1,
                 "actor" => "harness",
                 "occurred_at" => @fixed_now,
                 "idempotency_key" => "lease-prop-#{@grant_id_a}",
                 "payload" => EventPayload.execution_lease(lease_a)
               },
               trusted: [run_id: run_a.id]
             )

    assert {:ok, _} =
             Trajectory.append(
               goal.id,
               %{
                 "type" => "lease.granted",
                 "schema_version" => 1,
                 "actor" => "harness",
                 "occurred_at" => @fixed_now,
                 "idempotency_key" => "lease-grant-#{@grant_id_a}",
                 "payload" => %{"grant_id" => @grant_id_a}
               },
               trusted: [run_id: run_a.id]
             )

    assert {:ok, _} =
             Trajectory.append(
               goal.id,
               %{
                 "type" => "lease.active",
                 "schema_version" => 1,
                 "actor" => "harness",
                 "occurred_at" => @fixed_now,
                 "idempotency_key" => "lease-act-#{@grant_id_a}",
                 "payload" => %{"grant_id" => @grant_id_a}
               },
               trusted: [run_id: run_a.id]
             )

    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)
    assert Repo.get!(CapacitySnapshotRecord, snapshot_a.snapshot_id).capacity_state == "observed"
    lease_record_a = Repo.get!(ExecutionLeaseRecord, @grant_id_a)
    assert lease_record_a.status == "active"
    assert lease_record_a.admitted_snapshot_id == snapshot_a.snapshot_id
    assert lease_record_a.run_id == run_a.id

    # -------------------------------------------------------------------------
    # Step 2: Partial work events from Fake Adapter A
    # -------------------------------------------------------------------------
    assert {:ok, run_identity_a} = Fake.start(request_a, opts_a)
    assert run_identity_a.provider_session_id == "fake-session-quota"
    assert [recorded_start_a] = RequestLog.starts(log_a)
    assert recorded_start_a.dispatch_id == @dispatch_id_a

    assert {:ok, _} =
             Trajectory.append(
               goal.id,
               %{
                 "type" => "run.starting",
                 "schema_version" => 1,
                 "actor" => "harness",
                 "occurred_at" => @fixed_now,
                 "payload" => %{"run_id" => run_a.id}
               },
               trusted: [run_id: run_a.id]
             )

    assert {:ok, _} =
             Trajectory.append(
               goal.id,
               %{
                 "type" => "run.running",
                 "schema_version" => 1,
                 "actor" => "harness",
                 "occurred_at" => @fixed_now,
                 "payload" => %{
                   "run_id" => run_a.id,
                   "provider_session_id" => run_identity_a.provider_session_id
                 }
               },
               trusted: [run_id: run_a.id]
             )

    assert {:ok, events_a} = Fake.stream(run_identity_a, opts_a)
    partial_work_events = Enum.reject(events_a, &(&1.kind == :error))
    assert length(partial_work_events) >= 2
    assert Enum.any?(partial_work_events, &(&1.kind == :lifecycle))
    assert Enum.any?(partial_work_events, &(&1.kind == :output))

    for evt <- partial_work_events do
      assert {:ok, _} =
               Trajectory.append(
                 goal.id,
                 %{
                   "type" => "harness.event_recorded",
                   "schema_version" => 1,
                   "actor" => "harness",
                   "occurred_at" => evt.occurred_at,
                   "idempotency_key" => "evt-#{evt.source_event_id}",
                   "payload" => EventPayload.harness_event(evt)
                 },
                 trusted: [run_id: run_a.id]
               )
    end

    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)
    assert Repo.get!(RunRecord, run_a.id).status == "running"
    assert Repo.get!(RunRecord, run_a.id).provider_session_id == "fake-session-quota"

    # -------------------------------------------------------------------------
    # Step 3: Sudden quota refusal before an end-of-turn response
    # -------------------------------------------------------------------------
    refusal_event = Enum.find(events_a, &(&1.kind == :error))
    assert refusal_event != nil
    assert refusal_event.error.category == :quota_refused
    assert refusal_event.error.code == "rate_limit_exceeded"

    # Strict assertion: no terminal/result event was emitted before refusal
    refute Enum.any?(events_a, &(&1.kind == :result))

    assert {:ok, _} =
             Trajectory.append(
               goal.id,
               %{
                 "type" => "harness.event_recorded",
                 "schema_version" => 1,
                 "actor" => "harness",
                 "occurred_at" => refusal_event.occurred_at,
                 "idempotency_key" => "evt-#{refusal_event.source_event_id}",
                 "payload" => EventPayload.harness_event(refusal_event)
               },
               trusted: [run_id: run_a.id]
             )

    # Safe lease stop and run pause upon sudden refusal
    assert {:ok, _} =
             Trajectory.append(
               goal.id,
               %{
                 "type" => "lease.expired",
                 "schema_version" => 1,
                 "actor" => "harness",
                 "occurred_at" => @fixed_now,
                 "idempotency_key" => "lease-exp-#{@grant_id_a}",
                 "payload" => %{"grant_id" => @grant_id_a}
               },
               trusted: [run_id: run_a.id]
             )

    assert {:ok, _} =
             Trajectory.append(
               goal.id,
               %{
                 "type" => "run.pausing",
                 "schema_version" => 1,
                 "actor" => "harness",
                 "occurred_at" => @fixed_now,
                 "payload" => %{"run_id" => run_a.id}
               },
               trusted: [run_id: run_a.id]
             )

    assert {:ok, _} =
             Trajectory.append(
               goal.id,
               %{
                 "type" => "run.suspended",
                 "schema_version" => 1,
                 "actor" => "harness",
                 "occurred_at" => @fixed_now,
                 "payload" => %{"run_id" => run_a.id}
               },
               trusted: [run_id: run_a.id]
             )

    assert {:ok, _} =
             Trajectory.append(
               goal.id,
               %{
                 "type" => "lease.checkpoint_required",
                 "schema_version" => 1,
                 "actor" => "harness",
                 "occurred_at" => @fixed_now,
                 "idempotency_key" => "lease-ck-#{@grant_id_a}",
                 "payload" => %{"grant_id" => @grant_id_a}
               },
               trusted: [run_id: run_a.id]
             )

    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)
    assert Repo.get!(RunRecord, run_a.id).status == "suspended"
    assert Repo.get!(ExecutionLeaseRecord, @grant_id_a).status == "checkpoint_required"

    # -------------------------------------------------------------------------
    # Step 4: Deterministic Checkpoint creation without model inference
    # -------------------------------------------------------------------------
    assert {:ok, checkpoint} =
             Checkpoint.new(%{
               version: 1,
               checkpoint_id: @checkpoint_id,
               goal_id: goal.id,
               run_id: run_a.id,
               acceptance_contract: %{criteria: ["test suite passes", "clean demo output"]},
               repository_state: %{revision: "synthetic-git-rev-demo-1", dirty: false},
               evidence: ["partial work emitted prior to quota exhaustion"],
               decisions: ["suspended due to quota refusal", "handoff to second fake harness"],
               unresolved_issues: ["quota limit reached on adapter A"],
               next_action: "resume execution from checkpoint via adapter B",
               provider_session_id: run_identity_a.provider_session_id,
               stop_reason: "quota_refused",
               artifact_ids: [],
               extensions: %{"shoestring:synthesized_without_model" => true}
             })

    ck_payload = EventPayload.checkpoint(checkpoint)
    refute Map.has_key?(ck_payload, "model_summary")
    refute Map.has_key?(ck_payload, "summary")
    refute Map.has_key?(ck_payload, "conversation")
    assert ck_payload["stop_reason"] == "quota_refused"

    assert {:ok, _} =
             Trajectory.append(
               goal.id,
               %{
                 "type" => "checkpoint.created",
                 "schema_version" => 1,
                 "actor" => "harness",
                 "occurred_at" => @fixed_now,
                 "idempotency_key" => "ck-created-#{@checkpoint_id}",
                 "payload" => ck_payload
               },
               trusted: [run_id: run_a.id]
             )

    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)
    ck_record = Repo.get!(CheckpointRecord, @checkpoint_id)
    assert ck_record.stop_reason == "quota_refused"
    assert ck_record.next_action == "resume execution from checkpoint via adapter B"
    assert ck_record.provider_session_id == "fake-session-quota"

    # -------------------------------------------------------------------------
    # Step 5: Simulated application restart plus trajectory replay/projection reconstruction
    # -------------------------------------------------------------------------
    # Simulate restart by terminating the registered trajectory writer process
    assert [{writer_pid_before, _}] =
             Registry.lookup(Shoestring.Trajectory.WriterRegistry, goal.id)

    writer_ref = Process.monitor(writer_pid_before)

    assert :ok =
             DynamicSupervisor.terminate_child(
               Shoestring.Trajectory.WriterSupervisor,
               writer_pid_before
             )

    assert_receive {:DOWN, ^writer_ref, :process, ^writer_pid_before, reason}
    assert reason in [:normal, :shutdown]

    # Replay trajectory events purely from canonical event history
    assert {:ok, replayed_events} = Trajectory.replay(goal.id)
    assert length(replayed_events) >= 10
    assert {:ok, pure_state} = Projector.replay_events(replayed_events)
    assert pure_state.runs[run_a.id].status == :suspended
    assert pure_state.leases[@grant_id_a].status == :checkpoint_required
    assert pure_state.checkpoints[@checkpoint_id].stop_reason == "quota_refused"
    assert pure_state.capacity_snapshots[@snapshot_id_a].capacity_state == "observed"

    # Reconstruct projections from scratch by resetting derived tables and replaying from SQLite
    assert {:ok, rebuilt_position} = Projector.rebuild(goal.id, clock: FixedClock)
    assert rebuilt_position.status == "ok"

    # Confirm all derived records match the canonical trajectory state
    assert Repo.get!(RunRecord, run_a.id).status == "suspended"
    assert Repo.get!(ExecutionLeaseRecord, @grant_id_a).status == "checkpoint_required"
    assert Repo.get!(CheckpointRecord, @checkpoint_id).stop_reason == "quota_refused"
    assert Repo.get!(CapacitySnapshotRecord, @snapshot_id_a).capacity_state == "observed"

    # -------------------------------------------------------------------------
    # Step 6: Continuation through Fake Adapter B without raw Adapter A transcript
    # -------------------------------------------------------------------------
    scenario_b = Scenario.handoff_target(snapshot_id: @snapshot_id_b, now: @fixed_now)
    opts_b = %{scenario: scenario_b, clock: FixedClock, request_log: log_b}

    continuation_b = %{
      checkpoint_id: checkpoint.checkpoint_id,
      next_action: checkpoint.next_action,
      decision_refs: []
    }

    request_b =
      FakeHelpers.make_run_request(goal, task, @dispatch_id_b,
        continuation: continuation_b,
        prompt: "Complete the goal tasks using the structured checkpoint"
      )

    assert {:ok, run_b} =
             Runs.request(request_b, Fake.identity(),
               clock: FixedClock,
               identifier: Shoestring.Harness.SystemIdentifier
             )

    assert run_b.id != run_a.id
    assert run_b.status == "requested"
    assert run_b.dispatch_id == @dispatch_id_b

    # Verify writer restarted cleanly under supervision on first post-restart append
    assert [{writer_pid_after, _}] =
             Registry.lookup(Shoestring.Trajectory.WriterRegistry, goal.id)

    assert writer_pid_after != writer_pid_before

    # Propose and grant lease for Run B
    deadline_b = DateTime.add(@fixed_now, 3600, :second)

    assert {:ok, lease_b} =
             ExecutionLease.new(%{
               version: 1,
               grant_id: @grant_id_b,
               run_id: run_b.id,
               admitted_snapshot_id: snapshot_a.snapshot_id,
               reserves: %{response: 2, tool: 5},
               response_budget: 10,
               tool_budget: 20,
               deadline: deadline_b,
               checkpoint_cadence: 5,
               renewal_state: :none,
               extensions: %{}
             })

    assert {:ok, _} =
             Trajectory.append(
               goal.id,
               %{
                 "type" => "lease.proposed",
                 "schema_version" => 1,
                 "actor" => "harness",
                 "occurred_at" => @fixed_now,
                 "idempotency_key" => "lease-prop-#{@grant_id_b}",
                 "payload" => EventPayload.execution_lease(lease_b)
               },
               trusted: [run_id: run_b.id]
             )

    assert {:ok, _} =
             Trajectory.append(
               goal.id,
               %{
                 "type" => "lease.granted",
                 "schema_version" => 1,
                 "actor" => "harness",
                 "occurred_at" => @fixed_now,
                 "idempotency_key" => "lease-grant-#{@grant_id_b}",
                 "payload" => %{"grant_id" => @grant_id_b}
               },
               trusted: [run_id: run_b.id]
             )

    assert {:ok, _} =
             Trajectory.append(
               goal.id,
               %{
                 "type" => "lease.active",
                 "schema_version" => 1,
                 "actor" => "harness",
                 "occurred_at" => @fixed_now,
                 "idempotency_key" => "lease-act-#{@grant_id_b}",
                 "payload" => %{"grant_id" => @grant_id_b}
               },
               trusted: [run_id: run_b.id]
             )

    # Fake Adapter B receives prior identity pointer and resumes execution
    prior_identity = %RunIdentity{
      run_id: run_a.id,
      harness_id: "shoestring.harness.fake",
      process_id: nil,
      provider_session_id: run_identity_a.provider_session_id
    }

    assert {:ok, run_identity_b} = Fake.resume(prior_identity, request_b, opts_b)
    assert run_identity_b.provider_session_id == "fake-session-handoff-b"
    assert run_identity_b.provider_session_id != run_identity_a.provider_session_id

    # Privacy assertion: verify no raw Adapter A transcript was passed to Adapter B
    assert [recorded_request_b] = RequestLog.resumes(log_b)

    # The RunRequest struct contains no raw transcript or conversation fields
    refute Map.has_key?(recorded_request_b, :raw_transcript)
    refute Map.has_key?(recorded_request_b, :transcript)
    refute Map.has_key?(recorded_request_b, :conversation)
    refute Map.has_key?(recorded_request_b, :model_context)

    # Prompt contains only task instructions, not Adapter A's conversation
    refute String.contains?(recorded_request_b.prompt, "partial work")
    refute String.contains?(recorded_request_b.prompt, "rate_limit_exceeded")

    # Continuation only contains structured checkpoint references
    cont_b = recorded_request_b.continuation
    assert is_map(cont_b)
    assert cont_b.checkpoint_id == @checkpoint_id
    assert cont_b.next_action == "resume execution from checkpoint via adapter B"
    refute Map.has_key?(cont_b, :raw_context)
    refute Map.has_key?(cont_b, :raw_transcript)
    refute Map.has_key?(cont_b, :model_conversation)

    # -------------------------------------------------------------------------
    # Step 7: Verified terminal completion
    # -------------------------------------------------------------------------
    assert {:ok, _} =
             Trajectory.append(
               goal.id,
               %{
                 "type" => "run.starting",
                 "schema_version" => 1,
                 "actor" => "harness",
                 "occurred_at" => @fixed_now,
                 "payload" => %{"run_id" => run_b.id}
               },
               trusted: [run_id: run_b.id]
             )

    assert {:ok, _} =
             Trajectory.append(
               goal.id,
               %{
                 "type" => "run.running",
                 "schema_version" => 1,
                 "actor" => "harness",
                 "occurred_at" => @fixed_now,
                 "payload" => %{
                   "run_id" => run_b.id,
                   "provider_session_id" => run_identity_b.provider_session_id
                 }
               },
               trusted: [run_id: run_b.id]
             )

    assert {:ok, events_b} = Fake.stream(run_identity_b, opts_b)
    assert Enum.any?(events_b, &(&1.kind == :output))
    assert result_event_b = Enum.find(events_b, &(&1.kind == :result))
    assert result_event_b.result.status == "completed"

    for evt <- events_b do
      assert {:ok, _} =
               Trajectory.append(
                 goal.id,
                 %{
                   "type" => "harness.event_recorded",
                   "schema_version" => 1,
                   "actor" => "harness",
                   "occurred_at" => evt.occurred_at,
                   "idempotency_key" => "evt-#{evt.source_event_id}",
                   "payload" => EventPayload.harness_event(evt)
                 },
                 trusted: [run_id: run_b.id]
               )
    end

    assert {:ok, _} =
             Trajectory.append(
               goal.id,
               %{
                 "type" => "run.completed",
                 "schema_version" => 1,
                 "actor" => "harness",
                 "occurred_at" => @fixed_now,
                 "payload" => %{"run_id" => run_b.id}
               },
               trusted: [run_id: run_b.id]
             )

    assert {:ok, _} =
             Trajectory.append(
               goal.id,
               %{
                 "type" => "task.completed",
                 "schema_version" => 1,
                 "actor" => "harness",
                 "occurred_at" => @fixed_now,
                 "payload" => %{
                   "task_id" => task.id,
                   "result" => "completed successfully via fake adapter B"
                 }
               },
               trusted: [task_id: task.id]
             )

    # Final projection verification
    assert {:ok, final_position} = Projector.project(goal.id, clock: FixedClock)
    assert final_position.status == "ok"

    # Terminal state assertions
    assert Repo.get!(RunRecord, run_b.id).status == "completed"
    assert Repo.get!(ExecutionLeaseRecord, @grant_id_b).status == "active"
    assert Repo.get!(RunRecord, run_a.id).status == "suspended"
    assert Repo.get!(ExecutionLeaseRecord, @grant_id_a).status == "checkpoint_required"
    assert Repo.get!(CheckpointRecord, @checkpoint_id).stop_reason == "quota_refused"

    # Verify task status is completed via Trajectory.Projector
    assert {:ok, _} = Shoestring.Trajectory.Projector.project(goal.id)
    assert Repo.get!(Task, task.id).status == "completed"
  end
end
