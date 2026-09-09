defmodule Shoestring.Harness.ContinuationResumeTest do
  @moduledoc """
  Hermetic resume/handoff tests for `Elves.resume_run/3` with the Fake
  adapter, `RequestLog`, and canonical trajectory fixtures. No provider
  CLI, no network.

  Status per the standing contract: DOCUMENTATION, not regression locks.
  Everything here drives the new `Shoestring.Harness.Continuation` module
  and `Elves.resume_run/3`, so on the base commit (`d3ca088`) this file
  fails to compile with missing-module errors (the T1 precedent for
  new-surface documentation).

  Refusal ordering guarantee under test: every refusal happens BEFORE the
  adapter call, so the `RequestLog` stays empty on all refusal paths.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Elves
  alias Shoestring.Harness.{Continuation, Fake, Projector}
  alias Shoestring.Harness.Fake.{RequestLog, Scenario}
  alias Shoestring.Repo
  alias Shoestring.Test.CobblerHelpers
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.TrajectoryEvent

  import Ecto.Query

  @session "fake-session-resume"
  @next_action "resume from the established checkpoint"

  describe "same-run resume via Fake" do
    test "matching continuation resumes and records exact continuation keys" do
      fixture = resume_fixture()
      {:ok, log} = RequestLog.start()

      assert {:ok, identity} =
               Elves.resume_run(fixture.run.id,
                 adapter: Fake,
                 adapter_opts: %{
                   scenario: Scenario.same_session_resume(),
                   clock: Shoestring.Test.FixedClock,
                   request_log: log
                 },
                 continuation: fixture.presented,
                 provider_session_id: @session
               )

      assert identity.provider_session_id == "fake-session-resume"

      [recorded] = RequestLog.resumes(log)

      assert Enum.sort(Map.keys(recorded.continuation)) ==
               [:checkpoint_id, :decision_refs, :next_action]

      assert recorded.continuation.checkpoint_id == fixture.checkpoint_id
      assert recorded.continuation.next_action == @next_action
      assert recorded.continuation.decision_refs == [fixture.decision_id]

      # Forbidden runtime-term sweep on what the adapter received.
      for key <- Continuation.forbidden_keys() do
        refute Map.has_key?(recorded.continuation, key),
               "forbidden key #{key} reached the adapter"
      end

      # The RunRequest envelope legitimately carries :prompt (the task
      # prompt); the privacy boundary is the continuation, which must be a
      # bare checkpoint pointer.
      assert Shoestring.Harness.Security.scan_term(
               Map.new(recorded.continuation, fn {k, v} -> {to_string(k), v} end)
             ) ==
               []
    end

    test "stale checkpoint refuses before the adapter call" do
      fixture = resume_fixture()
      append_checkpoint!(fixture, "01950000-0000-7000-8000-0000000000c2", "newer next action")
      assert {:ok, _} = Projector.project(fixture.goal.id)

      {:ok, log} = RequestLog.start()

      assert {:error, :stale_continuation} =
               Elves.resume_run(fixture.run.id,
                 adapter: Fake,
                 adapter_opts: adapter_opts(log, Scenario.same_session_resume()),
                 continuation: fixture.presented,
                 provider_session_id: @session
               )

      assert RequestLog.count(log) == 0
    end

    test "superseded decision refs refuse before the adapter call" do
      fixture = resume_fixture()
      fresh_id = Ecto.UUID.generate()

      CobblerHelpers.append_admission_event!(
        fixture.goal.id,
        CobblerHelpers.admission_payload(decision_id: fresh_id)
      )

      {:ok, log} = RequestLog.start()

      assert {:error, :decision_superseded} =
               Elves.resume_run(fixture.run.id,
                 adapter: Fake,
                 adapter_opts: adapter_opts(log, Scenario.same_session_resume()),
                 continuation: fixture.presented,
                 provider_session_id: @session
               )

      assert RequestLog.count(log) == 0
    end

    test "unresumable lease refuses with no auto-renew and no adapter call" do
      fixture = resume_fixture()
      append_lease!(fixture.goal.id, fixture.run.id, fixture.grant_id, "lease.expired")

      append_lease!(
        fixture.goal.id,
        fixture.run.id,
        fixture.grant_id,
        "lease.checkpoint_required"
      )

      assert {:ok, _} = Projector.project(fixture.goal.id)

      assert Repo.get!(Shoestring.Harness.ExecutionLeaseRecord, fixture.grant_id).status ==
               "checkpoint_required"

      {:ok, log} = RequestLog.start()

      assert {:error, :lease_not_resumable} =
               Elves.resume_run(fixture.run.id,
                 adapter: Fake,
                 adapter_opts: adapter_opts(log, Scenario.same_session_resume()),
                 continuation: fixture.presented,
                 provider_session_id: @session
               )

      assert RequestLog.count(log) == 0
    end

    test "unknown future lease statuses are not resumable (pure unit)" do
      presented = %{checkpoint_id: "c", decision_refs: [], run_id: "r", provider_session_id: "s"}
      fresh = %{checkpoint_id: "c", decision_refs: [], run_id: "r", provider_session_id: "s"}

      assert :ok =
               Continuation.validate_resume(presented, fresh, %{lease_status: "active"})

      assert {:error, :lease_not_resumable} =
               Continuation.validate_resume(presented, fresh, %{lease_status: "future_locked"})
    end

    test "confirmation pending refuses before the adapter call" do
      fixture = resume_fixture()
      {:ok, log} = RequestLog.start()

      assert {:error, :confirmation_pending} =
               Elves.resume_run(fixture.run.id,
                 adapter: Fake,
                 adapter_opts: adapter_opts(log, Scenario.same_session_resume()),
                 continuation: fixture.presented,
                 provider_session_id: @session,
                 confirmation_pending: true
               )

      assert RequestLog.count(log) == 0
    end

    test "same-run different session refuses unless the adapter migrates" do
      fixture = resume_fixture()
      {:ok, log} = RequestLog.start()

      opts = [
        adapter: Fake,
        adapter_opts: adapter_opts(log, Scenario.same_session_resume()),
        continuation: fixture.presented,
        provider_session_id: "other-session"
      ]

      assert {:error, :session_mismatch} = Elves.resume_run(fixture.run.id, opts)
      assert RequestLog.count(log) == 0

      assert {:ok, _identity} =
               Elves.resume_run(
                 fixture.run.id,
                 Keyword.put(opts, :adapter_migrates_session, true)
               )
    end

    test "cobbler gate refuses without a claim before the adapter call" do
      fixture = resume_fixture()
      {:ok, log} = RequestLog.start()

      assert {:error, {:no_claimed_command, _}} =
               Elves.resume_run(fixture.run.id,
                 adapter: Fake,
                 adapter_opts: adapter_opts(log, Scenario.same_session_resume()),
                 continuation: fixture.presented,
                 provider_session_id: @session,
                 require_cobbler_command: true
               )

      assert RequestLog.count(log) == 0
    end
  end

  describe "cross-provider handoff via Fake handoff_target" do
    test "handoff creates a new run of the same goal plus the pointer event" do
      fixture = resume_fixture()
      {:ok, log} = RequestLog.start()
      handoff_id = Ecto.UUID.generate()
      new_run_id = Ecto.UUID.generate()
      new_dispatch_id = Ecto.UUID.generate()

      assert {:ok, %{handoff_id: ^handoff_id, run: new_run, run_identity: identity}} =
               Elves.resume_run(fixture.run.id,
                 adapter: Fake,
                 adapter_opts: adapter_opts(log, Scenario.handoff_target()),
                 continuation: fixture.presented,
                 provider_session_id: @session,
                 to_provider_id: "fake-harness-b",
                 reason: "quota handoff",
                 handoff_id: handoff_id,
                 new_run_id: new_run_id,
                 new_dispatch_id: new_dispatch_id
               )

      assert new_run.id == new_run_id
      assert new_run.goal_id == fixture.goal.id
      assert identity.provider_session_id == "fake-session-handoff-b"

      # Durable effect: the new run's run.requested carries the continuation.
      assert Repo.exists?(
               from event in TrajectoryEvent,
                 where:
                   event.goal_id == ^fixture.goal.id and event.type == "run.requested" and
                     event.run_id == ^new_run_id
             )

      # Pointer event with required fields and no forbidden content.
      handoff_event =
        Repo.one!(
          from event in TrajectoryEvent,
            where: event.goal_id == ^fixture.goal.id and event.type == "handoff.created",
            order_by: [desc: event.sequence],
            limit: 1
        )

      assert handoff_event.payload["handoff_id"] == handoff_id
      assert handoff_event.payload["run_id"] == new_run_id
      assert handoff_event.payload["checkpoint_id"] == fixture.checkpoint_id
      assert handoff_event.payload["prior_run_id"] == fixture.run.id
      assert handoff_event.payload["to_provider_id"] == "fake-harness-b"
      assert handoff_event.payload["reason"] == "quota handoff"
      assert handoff_event.payload["decision_refs"] == [fixture.decision_id]

      for key <- Continuation.forbidden_keys() do
        refute Map.has_key?(handoff_event.payload, Atom.to_string(key)),
               "forbidden key #{key} in handoff payload"
      end

      # I5 handoff correction (P2): cross-provider transfer starts a FRESH
      # session via adapter.start/2, never resume — the sender's session
      # identity is never presented to the target.
      [recorded] = RequestLog.starts(log)
      assert RequestLog.resumes(log) == []
      assert recorded.continuation.checkpoint_id == fixture.checkpoint_id
    end

    test "handoff from a terminal goal state is refused" do
      fixture = resume_fixture()
      {:ok, log} = RequestLog.start()

      assert {:error, {:handoff_not_allowed, _}} =
               Elves.resume_run(fixture.run.id,
                 adapter: Fake,
                 adapter_opts: adapter_opts(log, Scenario.handoff_target()),
                 continuation: fixture.presented,
                 provider_session_id: @session,
                 to_provider_id: "fake-harness-b",
                 goal_state: :handing_off
               )

      assert RequestLog.count(log) == 0
    end
  end

  # -- Fixture --

  defp resume_fixture do
    goal = FakeHelpers.insert_goal()
    task = FakeHelpers.insert_task(goal)
    dispatch_id = Ecto.UUID.generate()
    run = FakeHelpers.insert_run_record(goal, task, dispatch_id)
    snapshot_id = Ecto.UUID.generate()
    grant_id = Ecto.UUID.generate()
    checkpoint_id = Ecto.UUID.generate()
    decision_id = Ecto.UUID.generate()
    now = Shoestring.Test.FixedClock.now()

    append_event!(goal.id, run.id, "run.starting", %{"run_id" => run.id}, now)

    append_event!(
      goal.id,
      run.id,
      "run.running",
      %{
        "run_id" => run.id,
        "provider_session_id" => @session
      },
      now
    )

    append_event!(
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
      now,
      2
    )

    append_event!(
      goal.id,
      run.id,
      "lease.proposed",
      %{
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
      },
      now
    )

    append_lease!(goal.id, run.id, grant_id, "lease.granted")
    append_lease!(goal.id, run.id, grant_id, "lease.active")

    CobblerHelpers.append_admission_event!(
      goal.id,
      CobblerHelpers.admission_payload(decision_id: decision_id)
    )

    append_checkpoint!(%{goal: goal, run: run}, checkpoint_id, @next_action)

    assert {:ok, _} = Projector.project(goal.id)

    run = Repo.get!(Shoestring.Harness.RunRecord, run.id)

    %{
      goal: goal,
      task: task,
      run: run,
      grant_id: grant_id,
      checkpoint_id: checkpoint_id,
      decision_id: decision_id,
      presented: %{
        checkpoint_id: checkpoint_id,
        next_action: @next_action,
        decision_refs: [decision_id]
      }
    }
  end

  defp append_checkpoint!(%{goal: goal, run: run}, checkpoint_id, next_action) do
    append_event!(
      goal.id,
      run.id,
      "checkpoint.created",
      %{
        "checkpoint_id" => checkpoint_id,
        "run_id" => run.id,
        "contract_version" => 1,
        "acceptance_contract" => %{"criteria" => ["tests pass"]},
        "repository_state" => %{"revision" => "abc123", "dirty" => false},
        "evidence" => %{"items" => []},
        "decisions" => %{"items" => ["chose approach A"]},
        "unresolved_issues" => %{"items" => []},
        "next_action" => next_action,
        "provider_session_id" => @session,
        "stop_reason" => "quota_refused",
        "artifact_ids" => %{"items" => []},
        "extensions" => %{}
      },
      Shoestring.Test.FixedClock.now()
    )
  end

  defp append_lease!(goal_id, run_id, grant_id, type) do
    append_event!(
      goal_id,
      run_id,
      type,
      %{"grant_id" => grant_id},
      Shoestring.Test.FixedClock.now()
    )
  end

  defp append_event!(goal_id, run_id, type, payload, occurred_at, schema_version \\ 1) do
    assert {:ok, _event} =
             Trajectory.append(
               goal_id,
               %{
                 "type" => type,
                 "schema_version" => schema_version,
                 "actor" => "harness",
                 "occurred_at" => occurred_at,
                 "idempotency_key" =>
                   "#{type}:#{payload |> Map.values() |> inspect()}:#{System.unique_integer([:positive])}",
                 "payload" => payload
               },
               trusted: [run_id: run_id]
             )
  end

  defp adapter_opts(log, scenario) do
    %{scenario: scenario, clock: Shoestring.Test.FixedClock, request_log: log}
  end
end
