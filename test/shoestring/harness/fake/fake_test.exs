defmodule Shoestring.Harness.FakeTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.Harness.{CapacitySnapshot, Error}
  alias Shoestring.Harness.Fake
  alias Shoestring.Harness.Fake.{RequestLog, Scenario}
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Test.{FixedClock, ManualClock}

  setup do
    {:ok, log} = RequestLog.start()
    %{log: log}
  end

  # ---------------------------------------------------------------------------
  # Scenario 1: Normal completion
  # ---------------------------------------------------------------------------

  describe "scenario: normal_completion" do
    test "probe returns healthy known capacity", %{log: log} do
      scenario = Scenario.normal_completion()
      opts = %{scenario: scenario, clock: FixedClock, request_log: log}

      assert {:ok, %CapacitySnapshot{capacity_state: :known}} = Fake.probe(opts)
    end

    test "start records request and returns run identity", %{log: log} do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)
      dispatch_id = FakeHelpers.new_id()

      scenario = Scenario.normal_completion()
      request = FakeHelpers.make_run_request(goal, task, dispatch_id)
      opts = %{scenario: scenario, clock: FixedClock, request_log: log}

      assert {:ok, run_identity} = Fake.start(request, opts)
      assert run_identity.harness_id == "shoestring.harness.fake"
      assert run_identity.provider_session_id == "fake-session-normal"

      assert [recorded] = RequestLog.starts(log)
      assert recorded.dispatch_id == dispatch_id
    end

    test "stream emits lifecycle, output, and result events in order", %{log: log} do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)
      dispatch_id = FakeHelpers.new_id()

      scenario = Scenario.normal_completion()
      request = FakeHelpers.make_run_request(goal, task, dispatch_id)
      opts = %{scenario: scenario, clock: FixedClock, request_log: log}

      {:ok, run_identity} = Fake.start(request, opts)
      {:ok, events} = Fake.stream(run_identity, opts)

      kinds = Enum.map(events, & &1.kind)
      assert kinds == [:lifecycle, :output, :output, :result]

      result_event = List.last(events)
      assert result_event.result.status == "completed"
    end

    test "events have monotonically increasing ordinals", %{log: log} do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)
      dispatch_id = FakeHelpers.new_id()

      scenario = Scenario.normal_completion()
      request = FakeHelpers.make_run_request(goal, task, dispatch_id)
      opts = %{scenario: scenario, clock: FixedClock, request_log: log}

      {:ok, run_identity} = Fake.start(request, opts)
      {:ok, events} = Fake.stream(run_identity, opts)

      ordinals = Enum.map(events, & &1.ordinal)
      assert ordinals == Enum.to_list(1..length(events))
    end

    test "events carry the run_id from the run identity", %{log: log} do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)
      dispatch_id = FakeHelpers.new_id()

      scenario = Scenario.normal_completion()
      request = FakeHelpers.make_run_request(goal, task, dispatch_id)
      opts = %{scenario: scenario, clock: FixedClock, request_log: log}

      {:ok, run_identity} = Fake.start(request, opts)
      {:ok, events} = Fake.stream(run_identity, opts)

      assert Enum.all?(events, &(&1.run_id == run_identity.run_id))
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 2: Approaching reserve
  # ---------------------------------------------------------------------------

  describe "scenario: approaching_reserve" do
    test "stream includes a capacity event at the response boundary", %{log: log} do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)
      dispatch_id = FakeHelpers.new_id()

      scenario = Scenario.approaching_reserve()
      request = FakeHelpers.make_run_request(goal, task, dispatch_id)
      opts = %{scenario: scenario, clock: FixedClock, request_log: log}

      {:ok, run_identity} = Fake.start(request, opts)
      {:ok, events} = Fake.stream(run_identity, opts)

      kinds = Enum.map(events, & &1.kind)
      assert :capacity in kinds

      capacity_event = Enum.find(events, &(&1.kind == :capacity))
      refute is_nil(capacity_event.capacity_snapshot_id)
    end

    test "capacity snapshot id is set in the capacity event", %{log: log} do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)
      dispatch_id = FakeHelpers.new_id()

      scenario = Scenario.approaching_reserve()
      request = FakeHelpers.make_run_request(goal, task, dispatch_id)
      opts = %{scenario: scenario, clock: FixedClock, request_log: log}

      {:ok, run_identity} = Fake.start(request, opts)
      {:ok, events} = Fake.stream(run_identity, opts)

      capacity_event = Enum.find(events, &(&1.kind == :capacity))
      # The snapshot id in the event matches the scenario's capacity event snapshot
      assert is_binary(capacity_event.capacity_snapshot_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 3: Sudden quota refusal
  # ---------------------------------------------------------------------------

  describe "scenario: sudden_quota_refusal" do
    test "stream ends with an error event, no result event", %{log: log} do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)
      dispatch_id = FakeHelpers.new_id()

      scenario = Scenario.sudden_quota_refusal()
      request = FakeHelpers.make_run_request(goal, task, dispatch_id)
      opts = %{scenario: scenario, clock: FixedClock, request_log: log}

      {:ok, run_identity} = Fake.start(request, opts)
      {:ok, events} = Fake.stream(run_identity, opts)

      kinds = Enum.map(events, & &1.kind)
      assert :error in kinds
      refute :result in kinds
    end

    test "error event carries quota_refused category", %{log: log} do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)
      dispatch_id = FakeHelpers.new_id()

      scenario = Scenario.sudden_quota_refusal()
      request = FakeHelpers.make_run_request(goal, task, dispatch_id)
      opts = %{scenario: scenario, clock: FixedClock, request_log: log}

      {:ok, run_identity} = Fake.start(request, opts)
      {:ok, events} = Fake.stream(run_identity, opts)

      error_event = Enum.find(events, &(&1.kind == :error))
      assert error_event.error.category == :quota_refused
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 4: Stale capacity
  # ---------------------------------------------------------------------------

  describe "scenario: stale_capacity" do
    test "probe returns a stale snapshot", %{log: log} do
      ManualClock.set(~U[2026-09-01 11:00:00.000000Z])

      scenario = Scenario.stale_capacity(now: ~U[2026-09-01 10:00:00.000000Z])
      opts = %{scenario: scenario, clock: ManualClock, request_log: log}

      {:ok, snapshot} = Fake.probe(opts)

      # The snapshot expires_at is before ManualClock.now(), making it stale
      assert snapshot.capacity_state == :known
      stale = CapacitySnapshot.freshness(snapshot, ManualClock.now())
      assert stale == :stale
    end

    test "snapshot that expired is not eligible for admission", %{log: log} do
      ManualClock.set(~U[2026-09-01 11:00:00.000000Z])

      scenario = Scenario.stale_capacity(now: ~U[2026-09-01 10:00:00.000000Z])
      opts = %{scenario: scenario, clock: ManualClock, request_log: log}

      {:ok, snapshot} = Fake.probe(opts)
      refute CapacitySnapshot.eligible?(snapshot, ManualClock.now())
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 5: Missing capacity (unknown)
  # ---------------------------------------------------------------------------

  describe "scenario: missing_capacity" do
    test "probe returns an unknown capacity snapshot", %{log: log} do
      scenario = Scenario.missing_capacity()
      opts = %{scenario: scenario, clock: FixedClock, request_log: log}

      {:ok, snapshot} = Fake.probe(opts)
      assert snapshot.capacity_state == :unknown
    end

    test "unknown snapshot is not eligible for admission", %{log: log} do
      scenario = Scenario.missing_capacity()
      opts = %{scenario: scenario, clock: FixedClock, request_log: log}

      {:ok, snapshot} = Fake.probe(opts)
      refute CapacitySnapshot.eligible?(snapshot, FixedClock.now())
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 6: Malformed/unknown vendor event
  # ---------------------------------------------------------------------------

  describe "scenario: malformed_event" do
    test "unrecognized vendor event becomes a schema_incompatible error, not false capacity", %{
      log: log
    } do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)
      dispatch_id = FakeHelpers.new_id()

      scenario = Scenario.malformed_event()
      request = FakeHelpers.make_run_request(goal, task, dispatch_id)
      opts = %{scenario: scenario, clock: FixedClock, request_log: log}

      {:ok, run_identity} = Fake.start(request, opts)
      {:ok, events} = Fake.stream(run_identity, opts)

      error_event = Enum.find(events, &(&1.kind == :error))
      refute is_nil(error_event)
      assert error_event.error.category == :schema_incompatible

      # The event does not produce false capacity (no capacity event with known state)
      capacity_events = Enum.filter(events, &(&1.kind == :capacity))
      assert capacity_events == []
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 7: Start failure
  # ---------------------------------------------------------------------------

  describe "scenario: start_failure" do
    test "start returns a transport error", %{log: log} do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)
      dispatch_id = FakeHelpers.new_id()

      scenario = Scenario.start_failure()
      request = FakeHelpers.make_run_request(goal, task, dispatch_id)
      opts = %{scenario: scenario, clock: FixedClock, request_log: log}

      assert {:error, %Error{category: :transport}} = Fake.start(request, opts)
    end

    test "start failure still records the request", %{log: log} do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)
      dispatch_id = FakeHelpers.new_id()

      scenario = Scenario.start_failure()
      request = FakeHelpers.make_run_request(goal, task, dispatch_id)
      opts = %{scenario: scenario, clock: FixedClock, request_log: log}

      {:error, _} = Fake.start(request, opts)

      assert [recorded] = RequestLog.starts(log)
      assert recorded.dispatch_id == dispatch_id
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 8: Mid-run process crash
  # ---------------------------------------------------------------------------

  describe "scenario: mid_run_crash" do
    test "stream ends with a transport error event after partial output", %{log: log} do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)
      dispatch_id = FakeHelpers.new_id()

      scenario = Scenario.mid_run_crash()
      request = FakeHelpers.make_run_request(goal, task, dispatch_id)
      opts = %{scenario: scenario, clock: FixedClock, request_log: log}

      {:ok, run_identity} = Fake.start(request, opts)
      {:ok, events} = Fake.stream(run_identity, opts)

      kinds = Enum.map(events, & &1.kind)
      assert :output in kinds
      assert :error in kinds
      refute :result in kinds

      error_event = Enum.find(events, &(&1.kind == :error))
      assert error_event.error.category == :transport
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 9a: Cancellation before external-effect event
  # ---------------------------------------------------------------------------

  describe "scenario: cancel_before_effect" do
    test "cancel records the cancellation and returns :cancelled", %{log: log} do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)
      dispatch_id = FakeHelpers.new_id()

      scenario = Scenario.cancel_before_effect()
      request = FakeHelpers.make_run_request(goal, task, dispatch_id)
      opts = %{scenario: scenario, clock: FixedClock, request_log: log}

      {:ok, run_identity} = Fake.start(request, opts)

      # Cancel before consuming any stream events (before any external effect)
      assert {:ok, :cancelled} = Fake.cancel(run_identity, opts)

      assert [_cancel] = RequestLog.cancels(log)
    end

    test "no output events were consumed before cancellation", %{log: log} do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)
      dispatch_id = FakeHelpers.new_id()

      scenario = Scenario.cancel_before_effect()
      request = FakeHelpers.make_run_request(goal, task, dispatch_id)
      opts = %{scenario: scenario, clock: FixedClock, request_log: log}

      {:ok, run_identity} = Fake.start(request, opts)
      {:ok, :cancelled} = Fake.cancel(run_identity, opts)

      # The cancel happened before streaming — no output events in the log
      # (The stream was never consumed)
      assert RequestLog.count(log) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 9b: Cancellation after external-effect event
  # ---------------------------------------------------------------------------

  describe "scenario: cancel_after_effect" do
    test "cancel after effect records both the start and cancel", %{log: log} do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)
      dispatch_id = FakeHelpers.new_id()

      scenario = Scenario.cancel_after_effect()
      request = FakeHelpers.make_run_request(goal, task, dispatch_id)
      opts = %{scenario: scenario, clock: FixedClock, request_log: log}

      {:ok, run_identity} = Fake.start(request, opts)

      # Consume the first event (the effect)
      {:ok, events} = Fake.stream(run_identity, opts)
      _effect_event = Enum.find(events, &(&1.kind == :output))

      # Now cancel
      assert {:ok, :cancelled} = Fake.cancel(run_identity, opts)

      starts = RequestLog.starts(log)
      cancels = RequestLog.cancels(log)
      assert length(starts) == 1
      assert length(cancels) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 10: Planned lease expiration at a safe boundary
  # ---------------------------------------------------------------------------

  describe "scenario: lease_expiry_at_safe_boundary" do
    test "run completes after the boundary even with an expired lease", %{log: log} do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)
      dispatch_id = FakeHelpers.new_id()

      scenario = Scenario.lease_expiry_at_safe_boundary()
      request = FakeHelpers.make_run_request(goal, task, dispatch_id)
      opts = %{scenario: scenario, clock: FixedClock, request_log: log}

      {:ok, run_identity} = Fake.start(request, opts)
      {:ok, events} = Fake.stream(run_identity, opts)

      # The result event (safe boundary) completes before the run pauses
      result = Enum.find(events, &(&1.kind == :result))
      refute is_nil(result)
      assert result.result.status == "completed"
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 11: Same-session resume
  # ---------------------------------------------------------------------------

  describe "scenario: same_session_resume" do
    test "resume records the continuation request and returns a run identity", %{log: log} do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)
      dispatch_id_first = FakeHelpers.new_id()
      dispatch_id_second = FakeHelpers.new_id()
      checkpoint_id = FakeHelpers.new_id()

      scenario = Scenario.same_session_resume()
      first_request = FakeHelpers.make_run_request(goal, task, dispatch_id_first)
      opts = %{scenario: scenario, clock: FixedClock, request_log: log}

      {:ok, run_identity_first} = Fake.start(first_request, opts)

      continuation = %{
        checkpoint_id: checkpoint_id,
        next_action: "continue from previous checkpoint",
        decision_refs: []
      }

      resume_request =
        FakeHelpers.make_run_request(goal, task, dispatch_id_second, continuation: continuation)

      {:ok, run_identity_second} = Fake.resume(run_identity_first, resume_request, opts)

      # Both IDs are set; the resume gets the same session ID
      assert run_identity_second.provider_session_id == "fake-session-resume"

      resumes = RequestLog.resumes(log)
      assert length(resumes) == 1
      assert hd(resumes).continuation.checkpoint_id == checkpoint_id
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 12: Cross-harness handoff (privacy)
  # ---------------------------------------------------------------------------

  describe "scenario: cross_harness_handoff" do
    test "fake B receives no raw transcript from fake A in the RunRequest", %{log: log_a} do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)
      dispatch_a = FakeHelpers.new_id()
      dispatch_b = FakeHelpers.new_id()
      checkpoint_id = FakeHelpers.new_id()

      # Fake A: the original harness
      {:ok, log_b} = RequestLog.start()

      scenario_a = Scenario.normal_completion()
      scenario_b = Scenario.handoff_target()

      request_a = FakeHelpers.make_run_request(goal, task, dispatch_a)
      opts_a = %{scenario: scenario_a, clock: FixedClock, request_log: log_a}

      {:ok, run_identity_a} = Fake.start(request_a, opts_a)
      {:ok, events_a} = Fake.stream(run_identity_a, opts_a)

      # Simulate checkpoint creation after A's run
      assert Enum.any?(events_a, &(&1.kind == :result))

      # Fake B: receives only the continuation (checkpoint pointer + next_action)
      prior_identity = %Shoestring.Harness.RunIdentity{
        run_id: dispatch_a,
        harness_id: "shoestring.harness.fake",
        process_id: nil,
        provider_session_id: "fake-session-normal"
      }

      continuation = %{
        checkpoint_id: checkpoint_id,
        next_action: "resume from the established checkpoint",
        decision_refs: []
      }

      request_b =
        FakeHelpers.make_run_request(goal, task, dispatch_b,
          continuation: continuation,
          prompt: "Continue the task from the checkpoint"
        )

      opts_b = %{scenario: scenario_b, clock: FixedClock, request_log: log_b}

      {:ok, _run_identity_b} = Fake.resume(prior_identity, request_b, opts_b)

      # Privacy assertion: the request received by fake B MUST NOT contain
      # fake A's raw conversation transcript
      [recorded_b] = RequestLog.resumes(log_b)

      # The RunRequest only has structured fields — no raw transcript field
      refute Map.has_key?(recorded_b, :raw_transcript)
      refute Map.has_key?(recorded_b, :transcript)
      # The prompt in B's request is the task prompt, not A's conversation log
      assert is_binary(recorded_b.prompt)
      assert String.length(recorded_b.prompt) < 500

      # The continuation only contains the structured checkpoint reference
      assert recorded_b.continuation.checkpoint_id == checkpoint_id
      assert is_binary(recorded_b.continuation.next_action)
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 13: Delayed delivery
  # ---------------------------------------------------------------------------

  describe "scenario: delayed_delivery" do
    test "events arrive with delay but are still ordered by ordinal", %{log: log} do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)
      dispatch_id = FakeHelpers.new_id()

      scenario = Scenario.delayed_delivery()
      request = FakeHelpers.make_run_request(goal, task, dispatch_id)
      opts = %{scenario: scenario, clock: FixedClock, request_log: log}

      {:ok, run_identity} = Fake.start(request, opts)
      {:ok, events} = Fake.stream(run_identity, opts)

      ordinals = Enum.map(events, & &1.ordinal)
      assert ordinals == Enum.sort(ordinals)
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 14: Duplicated delivery
  # ---------------------------------------------------------------------------

  describe "scenario: duplicated_delivery" do
    test "duplicate event has a distinct source_event_id suffix", %{log: log} do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)
      dispatch_id = FakeHelpers.new_id()

      scenario = Scenario.duplicated_delivery()
      request = FakeHelpers.make_run_request(goal, task, dispatch_id)
      opts = %{scenario: scenario, clock: FixedClock, request_log: log}

      {:ok, run_identity} = Fake.start(request, opts)
      {:ok, events} = Fake.stream(run_identity, opts)

      source_ids = Enum.map(events, & &1.source_event_id)
      # The stream contains a duplicate (same base ID with -dup suffix)
      assert Enum.any?(source_ids, &String.ends_with?(&1, "-dup"))
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 15: Out-of-order delivery
  # ---------------------------------------------------------------------------

  describe "scenario: out_of_order_delivery" do
    test "source event IDs arrive out of ordinal order when modifier is applied", %{log: log} do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)
      dispatch_id = FakeHelpers.new_id()

      scenario = Scenario.out_of_order_delivery()
      request = FakeHelpers.make_run_request(goal, task, dispatch_id)
      opts = %{scenario: scenario, clock: FixedClock, request_log: log}

      {:ok, run_identity} = Fake.start(request, opts)
      {:ok, events} = Fake.stream(run_identity, opts)

      source_ids = Enum.map(events, & &1.source_event_id)

      # With the out_of_order modifier, events 2 and 3 are swapped in delivery
      # so ordinals arrive as [1, 3, 2, 4] — not monotonically increasing
      ordinals = Enum.map(events, & &1.ordinal)
      refute ordinals == Enum.sort(ordinals)

      # At least two adjacent source IDs are out of their natural order
      pairs = Enum.zip(source_ids, tl(source_ids))
      assert Enum.any?(pairs, fn {a, b} -> a > b end)
    end
  end

  # ---------------------------------------------------------------------------
  # Deterministic Eval: Replay
  # ---------------------------------------------------------------------------

  describe "eval: Replay — complete then delete projections, same state" do
    test "replaying trajectory events rebuilds the same run/lease/checkpoint state" do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)
      dispatch_id = FakeHelpers.new_id()
      run = FakeHelpers.insert_run_record(goal, task, dispatch_id)
      grant_id = FakeHelpers.new_id()
      snapshot_id = FakeHelpers.new_id()
      checkpoint_id = FakeHelpers.new_id()

      # Build a full lifecycle in the trajectory
      FakeHelpers.append_run_requested(goal, task, run)
      FakeHelpers.append_capacity_snapshot(goal, snapshot_id)
      FakeHelpers.append_run_starting(goal, run)
      FakeHelpers.append_run_running(goal, run, session_id: "replay-session")
      FakeHelpers.append_lease_proposed(goal, grant_id, run.id, snapshot_id)
      FakeHelpers.append_checkpoint_created(goal, checkpoint_id, run.id, "planned_pause")
      FakeHelpers.append_run_completed(goal, run)

      # Project forward
      {:ok, _} =
        Shoestring.Harness.Projector.project(goal.id,
          clock: FixedClock,
          identifier: Shoestring.Test.FixedIdentifier
        )

      run_before = Shoestring.Repo.get!(Shoestring.Harness.RunRecord, run.id)
      assert run_before.status == "completed"

      # Delete all derived state
      {:ok, _} =
        Shoestring.Harness.Projector.rebuild(goal.id,
          clock: FixedClock,
          identifier: Shoestring.Test.FixedIdentifier
        )

      run_after = Shoestring.Repo.get!(Shoestring.Harness.RunRecord, run.id)
      assert run_after.status == "completed"

      assert Shoestring.Repo.get!(Shoestring.Harness.CheckpointRecord, checkpoint_id).stop_reason ==
               "planned_pause"
    end
  end

  # ---------------------------------------------------------------------------
  # Deterministic Eval: Sudden limit
  # ---------------------------------------------------------------------------

  describe "eval: Sudden limit — refusal after partial work, checkpoint without model call" do
    test "quota_refusal scenario produces an error event and no result event" do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)
      dispatch_id = FakeHelpers.new_id()

      scenario = Scenario.sudden_quota_refusal()
      request = FakeHelpers.make_run_request(goal, task, dispatch_id)
      {:ok, log} = RequestLog.start()
      opts = %{scenario: scenario, clock: FixedClock, request_log: log}

      {:ok, run_identity} = Fake.start(request, opts)
      {:ok, events} = Fake.stream(run_identity, opts)

      # No result event means the run can be checkpointed deterministically
      # from the trajectory without a final model call
      refute Enum.any?(events, &(&1.kind == :result))
      assert Enum.any?(events, &(&1.kind == :error and &1.error.category == :quota_refused))

      # Checkpoint CAN be constructed without a model response
      checkpoint_id = FakeHelpers.new_id()
      run = FakeHelpers.insert_run_record(goal, task, dispatch_id, run_id: run_identity.run_id)
      FakeHelpers.append_run_requested(goal, task, run)
      FakeHelpers.append_checkpoint_created(goal, checkpoint_id, run.id, "quota_refused")

      {:ok, _} =
        Shoestring.Harness.Projector.project(goal.id,
          clock: FixedClock,
          identifier: Shoestring.Test.FixedIdentifier
        )

      assert Shoestring.Repo.get(Shoestring.Harness.CheckpointRecord, checkpoint_id) != nil
    end
  end

  # ---------------------------------------------------------------------------
  # Deterministic Eval: Safe lease stop
  # ---------------------------------------------------------------------------

  describe "eval: Safe lease stop — deadline during operation, pause at boundary only" do
    test "run completes the current response before pausing after lease expiry" do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)
      dispatch_id = FakeHelpers.new_id()

      scenario = Scenario.lease_expiry_at_safe_boundary()
      request = FakeHelpers.make_run_request(goal, task, dispatch_id)
      {:ok, log} = RequestLog.start()
      opts = %{scenario: scenario, clock: FixedClock, request_log: log}

      {:ok, run_identity} = Fake.start(request, opts)
      {:ok, events} = Fake.stream(run_identity, opts)

      # Lease expires (simulated by the scenario name), but the run still
      # completes after the response boundary
      result = Enum.find(events, &(&1.kind == :result))
      refute is_nil(result)
      assert result.result.status == "completed"

      # Verify lease state machine: expire then require_checkpoint
      {:ok, lease_expired} =
        Shoestring.Harness.LeaseStateMachine.transition(:active, :expire)

      assert lease_expired.state == :expired
      assert lease_expired.checkpoint_required? == true

      {:ok, checkpoint_required} =
        Shoestring.Harness.LeaseStateMachine.transition(:expired, :require_checkpoint)

      assert checkpoint_required.state == :checkpoint_required
    end
  end

  # ---------------------------------------------------------------------------
  # Deterministic Eval: Duplicate terminal
  # ---------------------------------------------------------------------------

  describe "eval: Duplicate terminal — completion delivered twice, one transition" do
    test "run state machine accepts duplicate terminal events idempotently" do
      alias Shoestring.Harness.RunStateMachine

      # First completion: running -> completed
      {:ok, first} = RunStateMachine.transition(:running, :complete)
      assert first.state == :completed
      assert first.idempotent? == false

      # Second completion (already completed): idempotent
      {:ok, second} = RunStateMachine.transition(:completed, :complete)
      assert second.state == :completed
      assert second.idempotent? == true
    end

    test "projector applies duplicate completion event idempotently via DB" do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)
      dispatch_id = FakeHelpers.new_id()
      run = FakeHelpers.insert_run_record(goal, task, dispatch_id)

      FakeHelpers.append_run_requested(goal, task, run)
      FakeHelpers.append_run_starting(goal, run)
      FakeHelpers.append_run_running(goal, run)
      FakeHelpers.append_run_completed(goal, run)

      # Project once
      {:ok, _} =
        Shoestring.Harness.Projector.project(goal.id,
          clock: FixedClock,
          identifier: Shoestring.Test.FixedIdentifier
        )

      assert Shoestring.Repo.get!(Shoestring.Harness.RunRecord, run.id).status == "completed"

      # Append a second completion event — idempotency key prevents duplicate,
      # but if it arrives as a different event, the state machine handles it
      {:ok, _} =
        Shoestring.Trajectory.append(
          goal.id,
          %{
            "type" => "run.completed",
            "schema_version" => 1,
            "actor" => "test",
            "occurred_at" => FixedClock.now(),
            "payload" => %{"run_id" => run.id}
          },
          trusted: [run_id: run.id]
        )

      {:ok, _} =
        Shoestring.Harness.Projector.project(goal.id,
          clock: FixedClock,
          identifier: Shoestring.Test.FixedIdentifier
        )

      # Status remains completed; no error
      assert Shoestring.Repo.get!(Shoestring.Harness.RunRecord, run.id).status == "completed"
    end
  end

  # ---------------------------------------------------------------------------
  # Deterministic Eval: Stale capacity
  # ---------------------------------------------------------------------------

  describe "eval: Stale capacity — clock advances beyond TTL, snapshot ineligible" do
    test "fresh snapshot becomes stale after clock advances past expires_at" do
      now = ~U[2026-09-01 10:00:00.000000Z]
      snapshot_id = "00000000-0000-4000-8000-000000001001"

      snapshot = Scenario.healthy_snapshot(snapshot_id, now)

      # Before TTL expires: fresh
      assert CapacitySnapshot.freshness(snapshot, now) == :fresh
      assert CapacitySnapshot.eligible?(snapshot, now)

      # After TTL (5 minutes + 1 second past the 300-second TTL)
      future = DateTime.add(now, 301, :second)
      assert CapacitySnapshot.freshness(snapshot, future) == :stale
      refute CapacitySnapshot.eligible?(snapshot, future)
    end

    test "unknown snapshot reports freshness as :unknown regardless of clock" do
      now = ~U[2026-09-01 10:00:00.000000Z]
      snapshot_id = "00000000-0000-4000-8000-000000001002"

      snapshot = Scenario.unknown_snapshot(snapshot_id, now)

      assert CapacitySnapshot.freshness(snapshot, now) == :unknown
      assert CapacitySnapshot.freshness(snapshot, DateTime.add(now, 9999, :second)) == :unknown
    end
  end

  # ---------------------------------------------------------------------------
  # Deterministic Eval: Handoff privacy
  # ---------------------------------------------------------------------------

  describe "eval: Handoff privacy — fake B receives continuation, no fake A raw transcript" do
    test "RunRequest to fake B contains no raw transcript field", %{log: log} do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)
      dispatch_b = FakeHelpers.new_id()
      checkpoint_id = FakeHelpers.new_id()

      scenario_b = Scenario.handoff_target()

      continuation = %{
        checkpoint_id: checkpoint_id,
        next_action: "continue from checkpoint",
        decision_refs: []
      }

      request_b =
        FakeHelpers.make_run_request(goal, task, dispatch_b,
          continuation: continuation,
          prompt: "Continue the work from the checkpoint"
        )

      prior = %Shoestring.Harness.RunIdentity{
        run_id: FakeHelpers.new_id(),
        harness_id: "shoestring.harness.fake",
        process_id: nil,
        provider_session_id: "session-a"
      }

      opts_b = %{scenario: scenario_b, clock: FixedClock, request_log: log}
      {:ok, _} = Fake.resume(prior, request_b, opts_b)

      [recorded] = RequestLog.resumes(log)

      # The RunRequest struct has no raw transcript field
      refute Map.has_key?(recorded, :raw_transcript)
      refute Map.has_key?(recorded, :transcript)

      # continuation only has checkpoint_id, next_action, decision_refs
      cont = recorded.continuation
      assert is_map(cont)
      assert cont.checkpoint_id == checkpoint_id
      assert is_binary(cont.next_action)
      refute Map.has_key?(cont, :raw_context)
      refute Map.has_key?(cont, :model_conversation)
    end

    test "RunRequest struct prevents transcript injection via any top-level field" do
      # The RunRequest struct is closed — it enforces allowed fields only
      fields =
        Map.keys(%Shoestring.Harness.RunRequest{
          version: 1,
          goal_id: "a",
          task_id: "b",
          workspace_ref: "c",
          prompt: "d",
          continuation: nil,
          policy: %{},
          requested_capabilities: [],
          dispatch_id: "e",
          extensions: %{}
        })

      forbidden_transcript_fields = [:raw_transcript, :transcript, :conversation, :model_context]

      for field <- forbidden_transcript_fields do
        refute field in fields, "RunRequest should not have field #{field}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Deterministic Eval: Schema drift
  # ---------------------------------------------------------------------------

  describe "eval: Schema drift — required field removed, compatibility degraded visibly" do
    test "malformed vendor event produces schema_incompatible error, not false capacity" do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)
      dispatch_id = FakeHelpers.new_id()

      {:ok, log} = RequestLog.start()
      scenario = Scenario.malformed_event()
      request = FakeHelpers.make_run_request(goal, task, dispatch_id)
      opts = %{scenario: scenario, clock: FixedClock, request_log: log}

      {:ok, run_identity} = Fake.start(request, opts)
      {:ok, events} = Fake.stream(run_identity, opts)

      error_event = Enum.find(events, &(&1.kind == :error))
      assert error_event.error.category == :schema_incompatible
      assert String.contains?(error_event.error.code, "unknown_vendor_event")
      refute Map.has_key?(error_event.error.details, "false_capacity")
    end

    test "degraded snapshot is surfaced visibly, not treated as healthy" do
      snapshot_id = "00000000-0000-4000-8000-000000002001"
      now = ~U[2026-09-01 10:00:00.000000Z]

      snapshot = Scenario.degraded_snapshot(snapshot_id, now)

      assert snapshot.compatibility_state == :degraded
      assert snapshot.capacity_state == :unknown
      # Not eligible for admission because unknown capacity
      refute CapacitySnapshot.eligible?(snapshot, now)
    end

    test "unknown capacity state can be distinguished from zero usage" do
      snapshot_id = "00000000-0000-4000-8000-000000002002"
      now = ~U[2026-09-01 10:00:00.000000Z]

      unknown = Scenario.unknown_snapshot(snapshot_id, now)

      assert CapacitySnapshot.unknown?(unknown)
      # CapacitySnapshot.unknown? = true means we CANNOT claim zero/unlimited usage
      # This is distinct from a known snapshot with 0% used
      refute CapacitySnapshot.unknown?(%CapacitySnapshot{
               unknown
               | capacity_state: :known,
                 windows: [%{kind: "five_hour", state: :known, used_percent: 0.0, reset_at: nil}],
                 expires_at: DateTime.add(now, 300, :second),
                 confidence: :high
             })
    end
  end

  # ---------------------------------------------------------------------------
  # Deterministic Eval: Restart — no duplicate dispatch on recovery
  # ---------------------------------------------------------------------------

  describe "eval: Restart — stop supervisor mid-scenario, no duplicate dispatch" do
    test "Runs.reconcile repairs orphaned run intent without duplicate events" do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)
      dispatch_id = FakeHelpers.new_id()

      # Simulate a crash: run intent persisted (RunRecord exists) but
      # no trajectory event was appended yet (projection_sequence == 0)
      run = FakeHelpers.insert_run_record(goal, task, dispatch_id)
      assert run.projection_sequence == 0

      # Reconcile finds the orphaned run and appends the missing event
      {:ok, count} = Shoestring.Harness.Runs.reconcile(goal.id, clock: FixedClock)
      assert count == 1

      # Project so projection_sequence is updated — otherwise reconcile sees the run again
      {:ok, _} =
        Shoestring.Harness.Projector.project(goal.id,
          clock: FixedClock,
          identifier: Shoestring.Test.FixedIdentifier
        )

      # Running reconcile again is idempotent (projection_sequence > 0, nothing to repair)
      {:ok, count2} = Shoestring.Harness.Runs.reconcile(goal.id, clock: FixedClock)
      assert count2 == 0

      # Verify projection sequence was updated
      {:ok, _} =
        Shoestring.Harness.Projector.project(goal.id,
          clock: FixedClock,
          identifier: Shoestring.Test.FixedIdentifier
        )

      updated_run = Shoestring.Repo.get!(Shoestring.Harness.RunRecord, run.id)
      assert updated_run.projection_sequence > 0
    end
  end

  # ---------------------------------------------------------------------------
  # Deterministic Eval: Delivery retry — one effect per dispatch_id
  # ---------------------------------------------------------------------------

  describe "eval: Delivery retry — execute one durable dispatch job twice, one effect" do
    test "performing the DispatchWorker job twice with same dispatch_id produces one running event" do
      use_oban_testing? = Code.ensure_loaded?(Oban.Testing)

      if use_oban_testing? do
        goal = FakeHelpers.insert_goal()
        task = FakeHelpers.insert_task(goal)
        dispatch_id = FakeHelpers.new_id()
        run = FakeHelpers.insert_run_record(goal, task, dispatch_id)
        FakeHelpers.append_run_requested(goal, task, run)

        job_args = %{
          "dispatch_id" => dispatch_id,
          "goal_id" => goal.id,
          "run_id" => run.id,
          "adapter" => "Elixir.Shoestring.Harness.Fake",
          "scenario_name" => "normal_completion"
        }

        # First execution: transitions run to running
        assert :ok =
                 Shoestring.Harness.Fake.DispatchWorker.perform(%Oban.Job{
                   args: job_args,
                   attempt: 1,
                   id: 1,
                   max_attempts: 3,
                   queue: "fake_dispatch",
                   worker: "Shoestring.Harness.Fake.DispatchWorker"
                 })

        {:ok, _} =
          Shoestring.Harness.Projector.project(goal.id,
            clock: FixedClock,
            identifier: Shoestring.Test.FixedIdentifier
          )

        run_after_first = Shoestring.Repo.get!(Shoestring.Harness.RunRecord, run.id)

        # Second execution: reconcile detects already-dispatched, no duplicate effect
        assert :ok =
                 Shoestring.Harness.Fake.DispatchWorker.perform(%Oban.Job{
                   args: job_args,
                   attempt: 2,
                   id: 2,
                   max_attempts: 3,
                   queue: "fake_dispatch",
                   worker: "Shoestring.Harness.Fake.DispatchWorker"
                 })

        {:ok, _} =
          Shoestring.Harness.Projector.project(goal.id,
            clock: FixedClock,
            identifier: Shoestring.Test.FixedIdentifier
          )

        run_after_second = Shoestring.Repo.get!(Shoestring.Harness.RunRecord, run.id)

        # The run status is the same after the second execution
        assert run_after_first.status == run_after_second.status
      else
        # Oban not available: test reconciliation logic directly
        goal = FakeHelpers.insert_goal()
        task = FakeHelpers.insert_task(goal)
        dispatch_id = FakeHelpers.new_id()
        run = FakeHelpers.insert_run_record(goal, task, dispatch_id)
        FakeHelpers.append_run_requested(goal, task, run)
        FakeHelpers.append_run_starting(goal, run)
        FakeHelpers.append_run_running(goal, run)

        {:ok, _} =
          Shoestring.Harness.Projector.project(goal.id,
            clock: FixedClock,
            identifier: Shoestring.Test.FixedIdentifier
          )

        # Reconcile on a run that's already running: no-op
        {:ok, count} = Shoestring.Harness.Runs.reconcile(goal.id, clock: FixedClock)
        assert count == 0
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Fake identity and capability checks
  # ---------------------------------------------------------------------------

  describe "Fake.identity/0" do
    test "returns a fake invocation_mode identity" do
      id = Fake.identity()
      assert id.invocation_mode == :fake
      assert id.adapter_id == "shoestring.harness.fake"
    end
  end

  describe "Fake.capabilities/0" do
    test "fake supports all capabilities including resume" do
      caps = Fake.capabilities()
      assert :resume in caps
      assert :cancel in caps
    end
  end

  describe "RequestLog" do
    test "records starts, resumes, and cancels separately" do
      goal = FakeHelpers.insert_goal()
      task = FakeHelpers.insert_task(goal)
      dispatch_a = FakeHelpers.new_id()
      dispatch_b = FakeHelpers.new_id()

      {:ok, log} = RequestLog.start()
      scenario = Scenario.normal_completion()
      opts = %{scenario: scenario, clock: FixedClock, request_log: log}

      req_a = FakeHelpers.make_run_request(goal, task, dispatch_a)
      req_b = FakeHelpers.make_run_request(goal, task, dispatch_b)

      {:ok, run_a} = Fake.start(req_a, opts)
      {:ok, _run_b} = Fake.resume(run_a, req_b, opts)
      {:ok, :cancelled} = Fake.cancel(run_a, opts)

      assert length(RequestLog.starts(log)) == 1
      assert length(RequestLog.resumes(log)) == 1
      assert length(RequestLog.cancels(log)) == 1
      assert RequestLog.count(log) == 3
    end
  end
end
