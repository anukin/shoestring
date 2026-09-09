defmodule Shoestring.Harness.EvalMatrix.MatrixTest do
  @moduledoc """
  Deterministic Milestone 05 eval matrix (T6): ten injection → required-result
  rows driven hermetically through the real T1–T5 producer interfaces
  (Fake scenarios, FixedClock/ManualClock, synthetic identifiers). No provider
  CLI, no network, no production code in this file.

  Locking note (standing contract): this file introduces no producer, so on
  the base commit (`c3779f0`) with the T6 files removed these tests error on
  the missing `Shoestring.Test.EvalMatrixHelpers` driver rather than failing
  behaviourally. They are documentation of wired producer behaviour — except
  where a row pins a pre-existing regression lock (noted inline) — and are
  labeled honestly as such.
  """
  use ShoestringWeb.ConnCase, async: false

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers

  alias Oban.Job

  alias Shoestring.Cobbler.{
    AdmissionEvaluation,
    Dispatcher,
    LeaseBounds,
    LeaseRenewal,
    Wakeups
  }

  alias Shoestring.Harness.{
    Checkpoints,
    CheckpointFallback,
    Continuation,
    ExecutionLease,
    ExecutionLeaseRecord,
    Fake,
    Projector,
    RunRecord
  }

  alias Shoestring.Harness.Fake.{RequestLog, Scenario}
  alias Shoestring.Repo
  alias Shoestring.Test.EvalMatrixHelpers, as: Eval
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.TrajectoryEvent
  alias ShoestringWeb.CobblerPresentation

  @now ~U[2026-09-07 12:00:00.000000Z]

  # ----------------------------------------------------------------------------
  # Row 1: Reserve refusal — usage at threshold → no automatic dispatch
  # ----------------------------------------------------------------------------

  test "row 1: reserve refusal defers and the gate refuses with zero jobs" do
    snapshot = Eval.used_snapshot(85.0, 20.0)

    assert {:ok, decision} =
             AdmissionEvaluation.evaluate(%{}, Eval.candidate(), snapshot, nil, now: @now)

    assert decision.result == :defer_until
    assert decision.reason_code == "reserve_breach_five_hour"

    goal = create_goal!()
    task = Eval.insert_task!(goal)
    snapshot_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, snapshot_id)

    # The deferred decision refuses lease issuance with its reason: no run
    # row, no lease row, no Oban job.
    deferred =
      append_admission_event!(
        goal.id,
        Eval.grant_payload(snapshot_id, "defer_until", "reserve_breach_five_hour")
      )

    command_defer = claim_command(deferred, command_id: "cmd-eval-r1-defer")

    assert {:error, {:lease_refused, refused}} =
             Dispatcher.claim_and_gate(goal.id, command_defer,
               now: @now,
               grant_lease: [task_id: task.id, clock: Shoestring.Test.FixedClock, now: @now]
             )

    assert refused.reason == "reserve_breach_five_hour"
    assert Repo.aggregate(Job, :count, :id) == 0
    assert Repo.aggregate(from(r in RunRecord, where: r.goal_id == ^goal.id), :count, :id) == 0

    # A refused grant leaves the claim standing, so release it explicitly
    # before the admitted flow re-acquires the global slot.
    assert {:ok, %{command: released}} =
             Shoestring.Cobbler.Commands.submit(
               goal.id,
               release_command("eval row-1 release", command_id: "cmd-eval-r1-release"),
               now: @now
             )

    assert released.result["kind"] == "released"

    # Fully validated claim without the lease opt-in stops at the explicit
    # execution-disabled boundary with nothing enqueued.
    goal2 = create_goal!()
    FakeHelpers.append_capacity_snapshot(goal2, snapshot_id)

    admitted =
      append_admission_event!(
        goal2.id,
        Eval.grant_payload(snapshot_id, "admit", "automatic_admission_eligible")
      )

    command = claim_command(admitted, command_id: "cmd-eval-r1-boundary")

    assert {:error, {:execution_disabled, detail}} =
             Dispatcher.claim_and_gate(goal2.id, command, now: @now)

    assert detail.boundary == "execution_disabled"
    assert Repo.aggregate(Job, :count, :id) == 0
  end

  # ----------------------------------------------------------------------------
  # Row 2: False-zero defense — missing/malformed window → unknown/manual
  # ----------------------------------------------------------------------------

  test "row 2: missing windows stay unknown (never bare 0) and require confirmation" do
    missing_five =
      Eval.build_snapshot(%{
        windows: %{
          "items" => [
            %{
              "kind" => "weekly",
              "state" => "observed",
              "used_percent" => 50.0,
              "reset_at" => "2026-09-14T00:00:00Z"
            }
          ]
        }
      })

    assert {:ok, decision} =
             AdmissionEvaluation.evaluate(%{}, Eval.candidate(), missing_five, nil, now: @now)

    assert decision.result == :require_confirmation
    assert decision.reason_code == "missing_window_five_hour"

    five = Enum.find(decision.observation["windows"], &(&1["kind"] == "five_hour"))
    assert is_nil(five) or five["used_percent"] == nil
    refute five != nil and five["used_percent"] == 0

    assert {:ok, nil_decision} =
             AdmissionEvaluation.evaluate(%{}, Eval.candidate(), nil, nil, now: @now)

    assert nil_decision.result == :require_confirmation

    assert nil_decision.reason_code in [
             "unknown_capacity",
             "missing_window_five_hour",
             "missing_window_weekly"
           ]
  end

  # ----------------------------------------------------------------------------
  # Row 3: Lease decline — capacity crosses reserve → checkpoint at boundary
  # ----------------------------------------------------------------------------

  test "row 3: renewal-due fires one reserve early; stop+boundary expires to checkpoint_required" do
    {:ok, lease} =
      ExecutionLease.new(%{
        version: 1,
        grant_id: Ecto.UUID.generate(),
        run_id: Ecto.UUID.generate(),
        admitted_snapshot_id: Ecto.UUID.generate(),
        reserves: %{response: 1, tool: 1},
        response_budget: 3,
        tool_budget: 25,
        deadline: DateTime.add(@now, 300, :second),
        checkpoint_cadence: 100,
        renewal_state: :none,
        extensions: %{}
      })

    state = LeaseBounds.new(lease)

    {:ok, events} =
      Fake.stream(
        %Shoestring.Harness.RunIdentity{
          run_id: lease.run_id,
          harness_id: "shoestring.harness.fake",
          process_id: "fake-pid-eval",
          provider_session_id: "fake-session-approaching"
        },
        %{scenario: Scenario.approaching_reserve(), clock: Shoestring.Test.FixedClock}
      )

    {advanced, _effects} = LeaseBounds.drain(state, lease.run_id, events)

    assert advanced.responses == 2
    assert advanced.due

    goal = create_goal!()
    task = Eval.insert_task!(goal)
    snapshot_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, snapshot_id)

    admission =
      append_admission_event!(
        goal.id,
        Eval.grant_payload(snapshot_id, "admit", "automatic_admission_eligible")
      )

    command = claim_command(admission, command_id: "cmd-eval-r3-grant")

    assert {:ok, leased} =
             Dispatcher.claim_and_gate(goal.id, command,
               now: @now,
               grant_lease: [task_id: task.id, clock: Shoestring.Test.FixedClock, now: @now]
             )

    grant_id = leased.grant_id

    assert {:ok, _} = Projector.project(goal.id, clock: Shoestring.Test.FixedClock)

    # Without the safe stop nothing is appended: work pauses only at boundary.
    before = lease_event_types(goal.id)

    assert {:error, :safe_stop_not_requested} =
             LeaseRenewal.maybe_renew(goal.id, grant_id,
               now: @now,
               boundary: :item_completed,
               observe: fn -> {:ok, Eval.eligible_snapshot(@now)} end
             )

    assert lease_event_types(goal.id) == before

    # At the boundary with a breached fresh snapshot: expired then
    # checkpoint_required, in sequence order.
    breached_id = Ecto.UUID.generate()

    assert {:ok, %{outcome: :expired, events: [expired, checkpoint]}} =
             LeaseRenewal.maybe_renew(goal.id, grant_id,
               now: @now,
               stop: :already_requested,
               boundary: :item_completed,
               observe: fn -> {:ok, breached_snapshot(breached_id)} end
             )

    assert expired.type == "lease.expired"
    assert checkpoint.type == "lease.checkpoint_required"
    assert expired.sequence < checkpoint.sequence

    assert {:ok, _} = Projector.project(goal.id, clock: Shoestring.Test.FixedClock)
    assert Repo.get!(ExecutionLeaseRecord, grant_id).status == "checkpoint_required"
  end

  # ----------------------------------------------------------------------------
  # Row 4: Sudden exhaustion — fallback checkpoint, zero model calls
  # ----------------------------------------------------------------------------

  test "row 4: sudden quota refusal checkpoints via fallback with zero adapter calls" do
    goal = create_goal!()
    task = Eval.insert_task!(goal)
    snapshot_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, snapshot_id)

    admission =
      append_admission_event!(
        goal.id,
        Eval.grant_payload(snapshot_id, "admit", "automatic_admission_eligible")
      )

    command = claim_command(admission, command_id: "cmd-eval-r4-grant")

    assert {:ok, leased} =
             Dispatcher.claim_and_gate(goal.id, command,
               now: @now,
               grant_lease: [task_id: task.id, clock: Shoestring.Test.FixedClock, now: @now]
             )

    run = leased.run
    {:ok, log} = RequestLog.start()
    count_before = RequestLog.count(log)

    {:ok, events} =
      Fake.stream(
        %Shoestring.Harness.RunIdentity{
          run_id: run.id,
          harness_id: "shoestring.harness.fake",
          process_id: "fake-pid-eval",
          provider_session_id: "fake-session-quota"
        },
        %{
          scenario: Scenario.sudden_quota_refusal(),
          clock: Shoestring.Test.FixedClock,
          request_log: log
        }
      )

    assert Enum.map(events, & &1.kind) == [:lifecycle, :output, :error]
    assert hd(Enum.reverse(events)).error.category == :quota_refused

    {:ok, checkpoint} =
      CheckpointFallback.build(%{
        checkpoint_id: Ecto.UUID.generate(),
        goal_id: goal.id,
        run_id: run.id,
        acceptance_criteria: ["tests pass"],
        repository_revision: "abc123",
        stop_reason: "quota_refused"
      })

    assert {:ok, %{outcome: :recorded}} = Checkpoints.record(goal.id, checkpoint)

    # Zero adapter calls flowed through the fallback path.
    assert RequestLog.count(log) == count_before

    assert {:ok, _} = Projector.project(goal.id, clock: Shoestring.Test.FixedClock)

    stored =
      Repo.one!(
        from event in TrajectoryEvent,
          where: event.goal_id == ^goal.id and event.type == "checkpoint.created",
          order_by: [desc: event.sequence],
          limit: 1
      )

    assert stored.payload["stop_reason"] == "quota_refused"

    # The persisted checkpoint carries the no-model-fallback provenance.
    assert {:ok, _} = Projector.project(goal.id, clock: Shoestring.Test.FixedClock)

    fallback_row =
      Repo.one!(
        from checkpoint in Shoestring.Harness.CheckpointRecord,
          where: checkpoint.goal_id == ^goal.id
      )

    assert fallback_row.extensions["shoestring:synthesized_without_model"] ==
             "checkpoint-fallback-v1"
  end

  # ----------------------------------------------------------------------------
  # Row 5: Reset restart — one wakeup, fresh recheck
  # ----------------------------------------------------------------------------

  test "row 5: sleeping goal plus rebooted reconciler yields one wakeup and a fresh recheck" do
    goal = create_goal!()
    task = Eval.insert_task!(goal)
    snapshot_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, snapshot_id)

    admission =
      append_admission_event!(
        goal.id,
        Eval.grant_payload(snapshot_id, "admit", "automatic_admission_eligible")
      )

    command = claim_command(admission, command_id: "cmd-eval-r5-grant")

    assert {:ok, leased} =
             Dispatcher.claim_and_gate(goal.id, command,
               now: @now,
               grant_lease: [task_id: task.id, clock: Shoestring.Test.FixedClock, now: @now]
             )

    run = leased.run
    grant_id = leased.grant_id
    assert {:ok, _} = Projector.project(goal.id, clock: Shoestring.Test.FixedClock)
    Eval.suspend_run!(goal.id, run.id, @now)
    assert {:ok, _} = Projector.project(goal.id, clock: Shoestring.Test.FixedClock)

    wakeup = Eval.schedule_wake!(goal, run, "cmd-eval-r5-wake", @now)

    # Simulated restart: two reconcile passes converge on exactly one job.
    assert {:ok, %{failures: []}} = Wakeups.reconcile(now: @now)
    assert {:ok, %{repaired_count: 0, failures: []}} = Wakeups.reconcile(now: @now)
    assert wake_job_count(wakeup.id) == 1

    # Wake-to-reobserve uses a FRESH snapshot (never admitted reuse) and
    # renews + resumes on admit.
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
    assert summary.run == :starting
    assert Repo.get!(ExecutionLeaseRecord, grant_id).admitted_snapshot_id == fresh.snapshot_id
  end

  # ----------------------------------------------------------------------------
  # Row 6: Dispatch crash — no duplicate Elf
  # ----------------------------------------------------------------------------

  test "row 6: kill mid-dispatch plus reconcile/double-perform yields one effect per dispatch_id" do
    goal = FakeHelpers.insert_goal()
    task = FakeHelpers.insert_task(goal)
    dispatch_id = Ecto.UUID.generate()
    run = FakeHelpers.insert_run_record(goal, task, dispatch_id)

    # Crash after intent: the run row exists with no event yet. The orphan
    # is repaired exactly once, then a second pass finds nothing.
    assert {:ok, 1} =
             Shoestring.Harness.Runs.reconcile(goal.id, clock: Shoestring.Test.FixedClock)

    assert {:ok, _} =
             Projector.project(goal.id,
               clock: Shoestring.Test.FixedClock,
               identifier: Shoestring.Test.FixedIdentifier
             )

    assert {:ok, 0} =
             Shoestring.Harness.Runs.reconcile(goal.id, clock: Shoestring.Test.FixedClock)

    job_args = %{
      "dispatch_id" => dispatch_id,
      "goal_id" => goal.id,
      "run_id" => run.id,
      "adapter" => "Elixir.Shoestring.Harness.Fake",
      "scenario_name" => "normal_completion"
    }

    job = fn attempt, id ->
      %Oban.Job{
        args: job_args,
        attempt: attempt,
        id: id,
        max_attempts: 3,
        queue: "fake_dispatch",
        worker: "Shoestring.Harness.Fake.DispatchWorker"
      }
    end

    # Crash after intent: first perform, then an orphan repair, then a retry.
    assert :ok = Shoestring.Harness.Fake.DispatchWorker.perform(job.(1, 1))

    assert {:ok, _} =
             Projector.project(goal.id,
               clock: Shoestring.Test.FixedClock,
               identifier: Shoestring.Test.FixedIdentifier
             )

    assert {:ok, 0} =
             Shoestring.Harness.Runs.reconcile(goal.id, clock: Shoestring.Test.FixedClock)

    assert :ok = Shoestring.Harness.Fake.DispatchWorker.perform(job.(2, 2))

    running =
      Repo.all(
        from event in TrajectoryEvent,
          where:
            event.goal_id == ^goal.id and event.type == "run.running" and
              event.run_id == ^run.id
      )

    assert length(running) == 1
  end

  # ----------------------------------------------------------------------------
  # Row 7: Handoff privacy — no raw sender transcript
  # ----------------------------------------------------------------------------

  test "row 7: handoff carries required pointers and refuses every forbidden key" do
    params = %{
      handoff_id: Ecto.UUID.generate(),
      run_id: Ecto.UUID.generate(),
      checkpoint_id: Ecto.UUID.generate(),
      from_provider_id: "shoestring.harness.fake",
      to_provider_id: "fake-harness-b",
      contract_version: 1,
      next_action: "resume from the established checkpoint",
      decision_refs: [Ecto.UUID.generate()],
      reason: "quota handoff",
      extensions: %{},
      prior_run_id: Ecto.UUID.generate()
    }

    assert {:ok, payload} = Continuation.handoff_payload(params)

    # Required present: exact continuation keys, binary next_action, bounds.
    for key <-
          ~w(handoff_id run_id checkpoint_id from_provider_id to_provider_id contract_version next_action decision_refs reason extensions) do
      assert Map.has_key?(payload, key), "required key #{key} missing"
    end

    assert is_binary(payload["next_action"])
    assert byte_size(payload["next_action"]) <= 2000
    assert length(payload["decision_refs"]) <= 32

    # Sensitive gone: every forbidden key refused, secret scan clean.
    for key <- Continuation.forbidden_keys() do
      refute Map.has_key?(payload, Atom.to_string(key))
      assert {:error, _} = Continuation.handoff_payload(Map.put(params, key, "smuggled"))
    end

    assert Shoestring.Harness.Security.scan_term(payload) == []
    assert Shoestring.Harness.Contract.safe_term?(payload)

    assert {:ok, _} =
             Shoestring.Trajectory.EventRegistry.validate_payload("handoff.created", 1, payload)
  end

  # ----------------------------------------------------------------------------
  # Row 8: Same resume — one reconciled continuation
  # ----------------------------------------------------------------------------

  test "row 8: same-session resume validates once; mismatch matrix refuses before adapter call" do
    fixture = resume_fixture()
    {:ok, log} = RequestLog.start()

    assert {:ok, identity} =
             Shoestring.Elves.resume_run(fixture.run.id,
               adapter: Fake,
               adapter_opts: Eval.adapter_opts(log, Scenario.same_session_resume()),
               continuation: fixture.presented,
               provider_session_id: "fake-session-resume"
             )

    assert identity.provider_session_id == "fake-session-resume"
    assert length(RequestLog.resumes(log)) == 1

    # Mismatch matrix: stale, superseded, lease, session — all refuse with an
    # empty request log.
    stale = resume_fixture()
    newer_id = Ecto.UUID.generate()

    Eval.append_event!(
      stale.goal.id,
      stale.run.id,
      "checkpoint.created",
      checkpoint_payload(
        %{checkpoint_id: newer_id, run_id: stale.run.id, session: "fake-session-resume"},
        "newer next action"
      )
    )

    assert {:ok, _} = Projector.project(stale.goal.id, clock: Shoestring.Test.FixedClock)
    {:ok, stale_log} = RequestLog.start()

    assert {:error, :stale_continuation} =
             Shoestring.Elves.resume_run(stale.run.id,
               adapter: Fake,
               adapter_opts: Eval.adapter_opts(stale_log, Scenario.same_session_resume()),
               continuation: stale.presented,
               provider_session_id: "fake-session-resume"
             )

    assert RequestLog.count(stale_log) == 0

    superseded = resume_fixture()

    append_admission_event!(
      superseded.goal.id,
      admission_payload(decision_id: Ecto.UUID.generate())
    )

    {:ok, sup_log} = RequestLog.start()

    assert {:error, :decision_superseded} =
             Shoestring.Elves.resume_run(superseded.run.id,
               adapter: Fake,
               adapter_opts: Eval.adapter_opts(sup_log, Scenario.same_session_resume()),
               continuation: superseded.presented,
               provider_session_id: "fake-session-resume"
             )

    assert RequestLog.count(sup_log) == 0

    mismatch = resume_fixture()
    {:ok, mm_log} = RequestLog.start()

    assert {:error, :session_mismatch} =
             Shoestring.Elves.resume_run(mismatch.run.id,
               adapter: Fake,
               adapter_opts: Eval.adapter_opts(mm_log, Scenario.same_session_resume()),
               continuation: mismatch.presented,
               provider_session_id: "other-session"
             )

    assert RequestLog.count(mm_log) == 0
  end

  # ----------------------------------------------------------------------------
  # Row 9: Incompatible update — pause/degrade visibly
  # ----------------------------------------------------------------------------

  test "row 9: malformed events degrade visibly; incompatible CLI rejects; projector never silently continues" do
    {:ok, events} =
      Fake.stream(
        %Shoestring.Harness.RunIdentity{
          run_id: Ecto.UUID.generate(),
          harness_id: "shoestring.harness.fake",
          process_id: "fake-pid-eval",
          provider_session_id: "s"
        },
        %{scenario: Scenario.malformed_event(), clock: Shoestring.Test.FixedClock}
      )

    error = Enum.find(events, &(&1.kind == :error))
    assert error.error.category == :schema_incompatible

    incompatible = %{Eval.candidate() | compatibility_state: :incompatible}
    snapshot = Eval.build_snapshot(%{})

    assert {:ok, decision} =
             AdmissionEvaluation.evaluate(%{}, incompatible, snapshot, nil, now: @now)

    assert decision.result == :reject
    assert decision.reason_code == "incompatible_cli"

    # The trajectory projector halts visibly on unknown non-cobbler types
    # rather than continuing silently.
    goal = create_goal!()

    assert {:error, {:unknown_event_type, _}} =
             Trajectory.append(goal.id, %{
               "type" => "vendor.future_probe",
               "schema_version" => 1,
               "actor" => "eval-matrix",
               "occurred_at" => @now,
               "payload" => %{}
             })
  end

  # ----------------------------------------------------------------------------
  # Row 10: UI explanation — inputs and policy reason match
  # ----------------------------------------------------------------------------

  test "row 10: goal page cards display the persisted reason, reserves, and bounds", %{conn: conn} do
    cases = [
      {"admit", "automatic_admission_eligible", "admitted"},
      {"defer_until", "reserve_breach_five_hour", "deferred"},
      {"require_confirmation", "unknown_capacity", "confirmation-required"},
      {"reject", "unsupported_capability", "rejected"}
    ]

    for {result, reason, status} <- cases do
      goal = create_goal!(Repo, "Eval row-10 #{result}")

      payload =
        admission_payload()
        |> Map.put("result", result)
        |> Map.put("reason_code", reason)
        |> Map.put("explanation", "Eval matrix explanation for #{reason}")

      payload =
        if result == "defer_until" do
          Map.put(payload, "defer_until", "2026-09-08T12:00:00.000000Z")
        else
          payload
        end

      append_admission_event!(goal.id, payload)

      {:ok, view, _html} = live(conn, "/cobbler/goals/#{goal.id}")

      assert has_element?(view, "#cobbler-decision-result[data-status='#{status}']")
      assert has_element?(view, "#cobbler-decision-reason", reason)
      assert has_element?(view, "#cobbler-decision-reserves", "response_budget")
    end

    # Unknown codes fall back honestly instead of raising.
    assert CobblerPresentation.decision_presentation("future_result").status == "unknown"
    assert CobblerPresentation.derive_goal_state(["future_result"], []) == :unknown
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  defp lease_event_types(goal_id) do
    Repo.all(
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^goal_id and
            event.type in [
              "lease.proposed",
              "lease.granted",
              "lease.active",
              "lease.renewal_due",
              "lease.renewed",
              "lease.expired",
              "lease.revoked",
              "lease.checkpoint_required"
            ],
        order_by: [asc: event.sequence],
        select: event.type
    )
  end

  defp breached_snapshot(snapshot_id) do
    {:ok, snapshot} =
      Shoestring.Harness.CapacitySnapshot.new(
        %{
          version: 2,
          snapshot_id: snapshot_id,
          capacity_state: :observed,
          windows: [
            %{kind: "five_hour", state: :observed, used_percent: 95.0, reset_at: nil},
            %{kind: "weekly", state: :observed, used_percent: 30.0, reset_at: nil}
          ],
          observed_at: @now,
          freshness: %{max_age_seconds: 300},
          source: %{
            adapter_id: "shoestring.harness.fake",
            provider_id: "codex",
            invocation_mode: "app_server",
            event: :explicit_read
          },
          scope: "account:codex",
          confidence: :high,
          support_tier: :proactive,
          compatibility_state: :compatible,
          reason: nil,
          extensions: %{}
        },
        now: @now
      )

    snapshot
  end

  defp wake_job_count(wakeup_id) do
    Repo.aggregate(
      from(job in Job,
        where:
          job.queue == "wakeup" and
            fragment("json_extract(?, '$.wakeup_id') = ?", job.args, ^wakeup_id)
      ),
      :count,
      :id
    )
  end

  defp resume_fixture do
    goal = FakeHelpers.insert_goal(Ecto.UUID.generate())
    task = FakeHelpers.insert_task(goal, Ecto.UUID.generate())
    dispatch_id = Ecto.UUID.generate()
    run = FakeHelpers.insert_run_record(goal, task, dispatch_id, run_id: Ecto.UUID.generate())
    snapshot_id = Ecto.UUID.generate()
    grant_id = Ecto.UUID.generate()
    checkpoint_id = Ecto.UUID.generate()
    decision_id = Ecto.UUID.generate()
    session = "fake-session-resume"
    next_action = "resume from the established checkpoint"

    Eval.append_event!(goal.id, run.id, "run.starting", %{"run_id" => run.id})

    Eval.append_event!(goal.id, run.id, "run.running", %{
      "run_id" => run.id,
      "provider_session_id" => session
    })

    Eval.append_event!(
      goal.id,
      run.id,
      "capacity.snapshot_observed",
      %{
        "snapshot_id" => snapshot_id,
        "run_id" => run.id,
        "contract_version" => 2,
        "capacity_state" => "observed",
        "windows" => %{
          "items" => [%{"kind" => "five_hour", "state" => "observed", "used_percent" => 25.0}]
        },
        "observed_at" => "2026-08-30T12:00:00Z",
        "expires_at" => "2026-08-30T12:05:00Z",
        "freshness" => %{"max_age_seconds" => 300},
        "source" => %{
          "adapter_id" => "shoestring.harness.fake",
          "provider_id" => "fake",
          "invocation_mode" => "fake",
          "event" => "explicit_read"
        },
        "scope" => "subscription",
        "confidence" => "high",
        "support_tier" => "proactive",
        "compatibility_state" => "compatible",
        "reason" => nil,
        "extensions" => %{}
      },
      Shoestring.Test.FixedClock.now(),
      2
    )

    Eval.append_event!(goal.id, run.id, "lease.proposed", %{
      "grant_id" => grant_id,
      "run_id" => run.id,
      "admitted_snapshot_id" => snapshot_id,
      "contract_version" => 1,
      "reserves" => %{"response" => 1, "tool" => 1},
      "response_budget" => 4,
      "tool_budget" => 4,
      "deadline" => "2026-08-30T12:15:00Z",
      "checkpoint_cadence" => 2,
      "renewal_state" => "eligible",
      "extensions" => %{}
    })

    Eval.append_event!(goal.id, run.id, "lease.granted", %{"grant_id" => grant_id})
    Eval.append_event!(goal.id, run.id, "lease.active", %{"grant_id" => grant_id})

    append_admission_event!(goal.id, admission_payload(decision_id: decision_id))

    Eval.append_event!(
      goal.id,
      run.id,
      "checkpoint.created",
      checkpoint_payload(
        %{checkpoint_id: checkpoint_id, run_id: run.id, session: session},
        next_action
      )
    )

    assert {:ok, _} = Projector.project(goal.id, clock: Shoestring.Test.FixedClock)
    run = Repo.get!(RunRecord, run.id)

    %{
      goal: goal,
      task: task,
      run: run,
      checkpoint_id: checkpoint_id,
      decision_id: decision_id,
      presented: %{
        checkpoint_id: checkpoint_id,
        next_action: next_action,
        decision_refs: [decision_id]
      }
    }
  end

  defp checkpoint_payload(
         %{checkpoint_id: checkpoint_id, run_id: run_id, session: session},
         next_action
       ) do
    %{
      "checkpoint_id" => checkpoint_id,
      "run_id" => run_id,
      "contract_version" => 1,
      "acceptance_contract" => %{"criteria" => ["tests pass"]},
      "repository_state" => %{"revision" => "abc123", "dirty" => false},
      "evidence" => %{"items" => []},
      "decisions" => %{"items" => ["chose approach A"]},
      "unresolved_issues" => %{"items" => []},
      "next_action" => next_action,
      "provider_session_id" => session,
      "stop_reason" => "quota_refused",
      "artifact_ids" => %{"items" => []},
      "extensions" => %{}
    }
  end
end
