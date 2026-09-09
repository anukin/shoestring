defmodule Shoestring.Harness.EvalMatrix.AblationTest do
  @moduledoc """
  Deterministic semantic ablation (T6): intact authored `next_action` vs
  fallback-template arms on the `sudden_quota_refusal → handoff_target`
  trajectory.

  PASS (asserted): the fallback arm still reaches `run.completed` with the
  privacy sweep green and a normalized terminal projection state
  byte-comparable to the intact arm. Per the brief, EITHER outcome would be
  recorded as informative; the deterministic tests here are authoritative and
  the manual-trajectory procedure plus scoring rubric live in
  `plans/evidence/05-quota-aware-mvp/ablation.md` for a later human run.

  Hermetic: Fake scenarios, FixedClock, synthetic identifiers only. No
  provider CLI, no network, no production code in this file.

  Locking note (standing contract): on the base commit (`c3779f0`) with the
  T6 files removed this file errors on the missing
  `Shoestring.Test.EvalMatrixHelpers` driver — documentation, not a
  behavior-change lock.
  """
  use Shoestring.DataCase, async: false

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers

  alias Shoestring.Harness.{
    CheckpointFallback,
    Continuation,
    Fake,
    Projector,
    RunRecord
  }

  alias Shoestring.Harness.Fake.{RequestLog, Scenario}
  alias Shoestring.Test.EvalMatrixHelpers, as: Eval
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Trajectory.TrajectoryEvent

  @authored_next_action "continue from step 3: implement the widget and run the suite"
  @session "fake-session-resume"

  test "fallback arm reaches completed with privacy green and comparable terminal state" do
    intact = run_arm(%{mode: :intact, command_id: "cmd-eval-ablation-intact"})
    fallback = run_arm(%{mode: :fallback, command_id: "cmd-eval-ablation-fallback"})

    assert intact.new_run_status == "completed"
    assert fallback.new_run_status == "completed"

    assert intact.privacy_scan == []
    assert fallback.privacy_scan == []

    assert intact.privacy_safe?
    assert fallback.privacy_safe?

    # Raw next_actions differ (ablation actually removed the authored text) ...
    assert intact.next_action == @authored_next_action
    assert fallback.next_action != @authored_next_action
    assert byte_size(fallback.next_action) > 0

    # ... yet the normalized terminal projection state is byte-comparable.
    assert :erlang.term_to_binary(intact.normalized) ==
             :erlang.term_to_binary(fallback.normalized)
  end

  # ----------------------------------------------------------------------------
  # Arm driver
  # ----------------------------------------------------------------------------

  defp run_arm(%{mode: mode, command_id: command_id}) do
    goal = FakeHelpers.insert_goal(Ecto.UUID.generate())
    task = FakeHelpers.insert_task(goal, Ecto.UUID.generate())

    run =
      FakeHelpers.insert_run_record(goal, task, Ecto.UUID.generate(),
        run_id: Ecto.UUID.generate()
      )

    snapshot_id = Ecto.UUID.generate()
    grant_id = Ecto.UUID.generate()
    checkpoint_id = Ecto.UUID.generate()
    decision_id = Ecto.UUID.generate()

    Eval.append_event!(goal.id, run.id, "run.starting", %{"run_id" => run.id})

    Eval.append_event!(goal.id, run.id, "run.running", %{
      "run_id" => run.id,
      "provider_session_id" => @session
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

    # Scripted interruption: partial work then quota refusal.
    {:ok, events} =
      Fake.stream(
        %Shoestring.Harness.RunIdentity{
          run_id: run.id,
          harness_id: "shoestring.harness.fake",
          process_id: "fake-pid-eval",
          provider_session_id: @session
        },
        %{scenario: Scenario.sudden_quota_refusal(), clock: Shoestring.Test.FixedClock}
      )

    assert Enum.map(events, & &1.kind) == [:lifecycle, :output, :error]

    next_action =
      case mode do
        :intact ->
          @authored_next_action

        :fallback ->
          {:ok, template} =
            CheckpointFallback.build(%{
              checkpoint_id: checkpoint_id,
              goal_id: goal.id,
              run_id: run.id,
              acceptance_criteria: ["tests pass"],
              repository_revision: "abc123",
              stop_reason: "quota_refused"
            })

          template.next_action
      end

    Eval.append_event!(goal.id, run.id, "checkpoint.created", %{
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
    })

    assert {:ok, _} = Projector.project(goal.id, clock: Shoestring.Test.FixedClock)

    # Checkpoint projection only (what Elf B receives): never the transcript.
    assert {:ok, continuation} = Continuation.for_goal(goal.id)
    assert continuation.checkpoint_id == checkpoint_id
    assert continuation.next_action == next_action

    {:ok, log} = RequestLog.start()
    new_run_id = Ecto.UUID.generate()

    assert {:ok, %{run: new_run}} =
             Shoestring.Elves.resume_run(run.id,
               adapter: Fake,
               adapter_opts: Eval.adapter_opts(log, Scenario.handoff_target()),
               continuation: %{
                 checkpoint_id: checkpoint_id,
                 next_action: next_action,
                 decision_refs: [decision_id]
               },
               provider_session_id: @session,
               to_provider_id: "fake-harness-b",
               reason: "quota handoff",
               new_run_id: new_run_id,
               new_dispatch_id: Ecto.UUID.generate()
             )

    # I5 handoff correction (P2): cross-provider transfer starts a FRESH
    # session via adapter.start/2, never resume.
    [recorded] = RequestLog.starts(log)
    assert RequestLog.resumes(log) == []

    scan =
      Shoestring.Harness.Security.scan_term(
        Map.new(recorded.continuation, fn {k, v} -> {to_string(k), v} end)
      )

    Eval.append_event!(goal.id, new_run.id, "run.starting", %{"run_id" => new_run.id})

    Eval.append_event!(goal.id, new_run.id, "run.running", %{
      "run_id" => new_run.id,
      "provider_session_id" => "fake-session-handoff-b"
    })

    Eval.append_event!(goal.id, new_run.id, "run.completed", %{"run_id" => new_run.id})

    assert {:ok, _} = Projector.project(goal.id, clock: Shoestring.Test.FixedClock)

    new_status = Repo.get!(RunRecord, new_run.id).status

    handoff_event =
      Repo.one!(
        from event in TrajectoryEvent,
          where: event.goal_id == ^goal.id and event.type == "handoff.created",
          order_by: [desc: event.sequence],
          limit: 1
      )

    _ = command_id

    %{
      next_action: next_action,
      new_run_status: new_status,
      privacy_scan: scan,
      privacy_safe?:
        Shoestring.Harness.Contract.safe_term?(
          Map.new(recorded.continuation, fn {k, v} -> {to_string(k), v} end)
        ),
      normalized: %{
        run_status: new_status,
        decision_ref_count: length(handoff_event.payload["decision_refs"]),
        reason: handoff_event.payload["reason"],
        to_provider: handoff_event.payload["to_provider_id"],
        next_action_present?: byte_size(next_action) > 0,
        stop: "quota_refused"
      }
    }
  end
end
