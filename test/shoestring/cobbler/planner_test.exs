defmodule Shoestring.Cobbler.PlannerTest do
  @moduledoc """
  Hermetic feature tests for the bounded planner boundary.

  Every test runs the real domain (`Shoestring.Cobbler.Planner` through the
  `Shoestring.Cobbler` facade where the boundary is public) against the
  deterministic fixture planner and explicit capacity snapshots. No provider
  CLI is touched and no network is used: quota-blocked paths assert zero
  fixture invocations, and repair paths assert at most two.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Cobbler
  alias Shoestring.Cobbler.PlannerHttp
  alias Shoestring.Cobbler.PlannerRequestRecord
  alias Shoestring.Test.{CobblerHelpers, PlanFixtures, PlannerHelpers}

  setup do
    goal = PlannerHelpers.create_goal!()
    log = PlannerHelpers.start_log!()
    {:ok, %{goal: goal, log: log}}
  end

  defp opts(log, snapshot, extra \\ []) do
    PlannerHelpers.call_opts(log, snapshot, extra)
  end

  defp admitted(log, extra \\ []) do
    opts(log, PlannerHelpers.admitted_snapshot(), extra)
  end

  defp event_types(goal, types) do
    CobblerHelpers.event_count(goal.id, types)
  end

  describe "valid proposals" do
    test "a valid DAG persists an immutable unapproved revision with provenance", %{
      goal: goal,
      log: log
    } do
      assert {:ok, %{request: request, revision: revision, outcome: :recorded, events: events}} =
               Cobbler.request_plan(goal.id, PlannerHelpers.request_attrs(), admitted(log))

      assert request.status == "proposed"
      assert request.attempts_used == 1
      assert request.requested_by == "human:planner"
      assert request.planner_identity == "fixture-planner"

      assert revision.status == "proposed"
      assert revision.authored_by == "human:planner"
      assert revision.author_kind == "human"

      # Planner provenance is recorded inside the plan; it authorizes nothing.
      assert revision.content["planner"]["identity"] == "fixture-planner"
      assert revision.content["planner"]["version"] == "1"

      # Nothing is approved: the proposal sits inert until a human decides.
      assert Cobbler.plan_authority(goal.id) == nil

      # Accounting: one admission per invocation, plus the request lifecycle.
      assert event_types(goal, ["admission.decided"]) == 1
      assert event_types(goal, ["cobbler.planner.requested"]) == 1
      assert event_types(goal, ["cobbler.planner.resolved"]) == 1
      assert events != []

      # The approval flow from package A closes the loop for a human.
      assert {:ok, %{revision: approved}} =
               Cobbler.approve_plan(
                 goal.id,
                 PlanFixtures.approve_attrs(revision.revision_number, revision.digest)
               )

      assert approved.status == "approved"
      assert Cobbler.plan_authority(goal.id).revision_number == revision.revision_number
    end

    test "the default fixture derives its plan from the prompt goal", %{goal: goal, log: log} do
      attrs = PlannerHelpers.request_attrs(goal_statement: "Keep the gate green on every commit.")

      assert {:ok, %{revision: revision}} = Cobbler.request_plan(goal.id, attrs, admitted(log))
      assert revision.content["goal"]["statement"] == "Keep the gate green on every commit."

      assert revision.content["goal"]["repository"]["base_revision"] ==
               PlanFixtures.base_revision()
    end

    test "redaction removes secrets while preserving the necessary fields", %{
      goal: goal,
      log: log
    } do
      # Removal: a credential anywhere in the inputs refuses the request
      # before anything is claimed or admitted.
      secret_attrs =
        PlannerHelpers.request_attrs(constraints: ["Deploy with api_key: hunter2-deploy"])

      assert {:error, {:invalid_planner_request, :constraints, _message}} =
               Cobbler.request_plan(goal.id, secret_attrs, admitted(log))

      assert Cobbler.list_planner_requests(goal.id) == []
      assert event_types(goal, ["cobbler.planner.requested"]) == 0

      # Preservation: the stored request keeps the statement, revision, and
      # context references the prompt was built from.
      assert {:ok, %{request: request}} =
               Cobbler.request_plan(goal.id, PlannerHelpers.request_attrs(), admitted(log))

      assert request.goal_statement =~ "plan revisions"
      assert request.base_revision == PlanFixtures.base_revision()

      assert request.source_context_refs == %{
               "refs" => [
                 %{
                   "ref" => "docs/plan-contract.md",
                   "summary" => "The plan contract and its bounds."
                 }
               ]
             }
    end

    test "absolute machine paths are refused in committed artifacts", %{goal: goal, log: log} do
      attrs = PlannerHelpers.request_attrs(goal_statement: "Fix /Users/someone/projects/app now.")

      assert {:error, {:invalid_planner_request, :goal_statement, _message}} =
               Cobbler.request_plan(goal.id, attrs, admitted(log))

      assert Cobbler.list_planner_requests(goal.id) == []
    end
  end

  describe "human authority" do
    test "a non-human initiator cannot request a plan", %{goal: goal, log: log} do
      attrs = PlannerHelpers.request_attrs(requested_by: "planner:fixture")

      assert {:error, {:non_human_identity, _detail}} =
               Cobbler.request_plan(goal.id, attrs, admitted(log))

      assert Cobbler.list_planner_requests(goal.id) == []
    end

    test "the planner cannot approve its own proposal", %{goal: goal, log: log} do
      assert {:ok, %{revision: revision}} =
               Cobbler.request_plan(goal.id, PlannerHelpers.request_attrs(), admitted(log))

      assert {:error, {:non_human_identity, _detail}} =
               Cobbler.approve_plan(
                 goal.id,
                 PlanFixtures.approve_attrs(revision.revision_number, revision.digest,
                   decision_id: "decision-model",
                   decided_by: "planner:fixture"
                 )
               )

      assert Cobbler.plan_authority(goal.id) == nil
    end

    test "a human rejection stays a durable attributable fact", %{goal: goal, log: log} do
      assert {:ok, %{revision: revision}} =
               Cobbler.request_plan(goal.id, PlannerHelpers.request_attrs(), admitted(log))

      assert {:ok, %{revision: rejected}} =
               Cobbler.reject_plan(
                 goal.id,
                 PlanFixtures.reject_attrs(revision.revision_number, revision.digest)
               )

      assert rejected.status == "rejected"
      assert Cobbler.plan_authority(goal.id) == nil
    end
  end

  describe "quota-blocked planning" do
    test "a reserve breach settles to the manual path with zero invocations", %{
      goal: goal,
      log: log
    } do
      blocked = opts(log, PlannerHelpers.blocked_snapshot())

      assert {:error, {:planner_quota_blocked, detail}} =
               Cobbler.request_plan(goal.id, PlannerHelpers.request_attrs(), blocked)

      assert detail["reason_code"] == "reserve_breach_five_hour"
      assert Shoestring.Test.PlannerCallLog.count(log) == 0

      [request] = Cobbler.list_planner_requests(goal.id)
      assert request.status == "manual_required"
      assert request.error_kind == "quota_blocked"
      assert request.attempts_used == 0

      # The blocked evaluation is still durable accounting.
      assert event_types(goal, ["admission.decided"]) == 1
      assert event_types(goal, ["cobbler.planner.resolved"]) == 1
      assert Cobbler.list_plan_revisions(goal.id) == []
    end

    test "unknown capacity needs a confirmation, and a human one admits", %{goal: goal, log: log} do
      stale = opts(log, PlannerHelpers.stale_snapshot())

      assert {:error, {:planner_confirmation_required, detail}} =
               Cobbler.request_plan(goal.id, PlannerHelpers.request_attrs(), stale)

      assert detail["reason_code"] == "stale_observation"
      assert Shoestring.Test.PlannerCallLog.count(log) == 0
      assert Cobbler.list_plan_revisions(goal.id) == []

      # The same request under a new id with an attributable human
      # confirmation is admitted: manual responsibility, not bypassed reserves.
      confirmed_attrs =
        PlannerHelpers.request_attrs(
          request_id: "plan-request-2",
          confirmation: %{confirmed_by: "human:operator", intent: "manual_plan_review"}
        )

      assert {:ok, %{revision: revision}} =
               Cobbler.request_plan(goal.id, confirmed_attrs, stale)

      assert revision.status == "proposed"
      assert Shoestring.Test.PlannerCallLog.count(log) == 1
    end
  end

  describe "invalid output and bounded repair" do
    test "a cyclic plan fails validation and never persists", %{goal: goal, log: log} do
      fixture = %{plans: [PlannerHelpers.cyclic_plan(), PlannerHelpers.cyclic_plan()]}

      assert {:error, {:planner_manual_required, detail}} =
               Cobbler.request_plan(
                 goal.id,
                 PlannerHelpers.request_attrs(),
                 admitted(log, fixture: fixture)
               )

      assert detail["attempts_used"] == 2
      assert detail["validation_errors"] != []
      assert Enum.any?(detail["validation_errors"], &(&1 =~ "cycle"))
      assert Shoestring.Test.PlannerCallLog.count(log) == 2
      assert Cobbler.list_plan_revisions(goal.id) == []

      [request] = Cobbler.list_planner_requests(goal.id)
      assert request.status == "manual_required"
      assert request.error_kind == "repair_exhausted"
      assert request.attempts_used == 2
    end

    test "a task without acceptance criteria reaches the manual path", %{goal: goal, log: log} do
      fixture = %{
        plans: [PlannerHelpers.missing_criterion_plan(), PlannerHelpers.missing_criterion_plan()]
      }

      assert {:error, {:planner_manual_required, _detail}} =
               Cobbler.request_plan(
                 goal.id,
                 PlannerHelpers.request_attrs(),
                 admitted(log, fixture: fixture)
               )

      assert Shoestring.Test.PlannerCallLog.count(log) == 2
      assert Cobbler.list_plan_revisions(goal.id) == []
    end

    test "repair succeeds when the second attempt validates", %{goal: goal, log: log} do
      fixture = %{plans: [PlannerHelpers.cyclic_plan(), PlannerHelpers.valid_plan()]}

      assert {:ok, %{revision: revision, request: request}} =
               Cobbler.request_plan(
                 goal.id,
                 PlannerHelpers.request_attrs(),
                 admitted(log, fixture: fixture)
               )

      assert revision.status == "proposed"
      assert request.attempts_used == 2
      assert Shoestring.Test.PlannerCallLog.count(log) == 2
      assert event_types(goal, ["admission.decided"]) == 2

      # The repair carried the bounded validation errors, not raw output.
      [{_first_prompt, 1}, {repair_prompt, 2}] = Shoestring.Test.PlannerCallLog.calls(log)
      repair_errors = get_in(repair_prompt, ["instructions", "repair", "errors"])
      assert is_list(repair_errors) and repair_errors != []
      assert Enum.any?(repair_errors, &(&1 =~ "cycle"))
    end

    test "no third attempt happens after the budget is spent", %{goal: goal, log: log} do
      fixture =
        %{
          plans: [
            PlannerHelpers.cyclic_plan(),
            PlannerHelpers.cyclic_plan(),
            PlannerHelpers.valid_plan()
          ]
        }

      assert {:error, {:planner_manual_required, _detail}} =
               Cobbler.request_plan(
                 goal.id,
                 PlannerHelpers.request_attrs(),
                 admitted(log, fixture: fixture)
               )

      # Even though a third plan would validate, the budget is spent.
      assert Shoestring.Test.PlannerCallLog.count(log) == 2
      assert Cobbler.list_plan_revisions(goal.id) == []

      # Replaying the identical request replays the manual outcome with no
      # new invocation: limits are durable across replay.
      assert {:error, {:planner_manual_required, _detail}} =
               Cobbler.request_plan(
                 goal.id,
                 PlannerHelpers.request_attrs(),
                 admitted(log, fixture: fixture)
               )

      assert Shoestring.Test.PlannerCallLog.count(log) == 2
    end
  end

  describe "unsafe proposals and transport failures" do
    test "an unsafe proposal is terminal with no repair and no revision", %{goal: goal, log: log} do
      assert {:error, {:planner_unsafe_proposal, detail}} =
               Cobbler.request_plan(
                 goal.id,
                 PlannerHelpers.request_attrs(),
                 admitted(log, fixture: %{plan: PlannerHelpers.unsafe_plan()})
               )

      assert detail["request_id"] == "plan-request-1"
      assert Shoestring.Test.PlannerCallLog.count(log) == 1
      assert Cobbler.list_plan_revisions(goal.id) == []

      [request] = Cobbler.list_planner_requests(goal.id)
      assert request.status == "failed"
      assert request.error_kind == "unsafe_proposal"
    end

    test "a transport error is terminal and accounted", %{goal: goal, log: log} do
      fixture = %{errors: [{:transport, %{"reason" => "timeout"}}]}

      assert {:error, {:planner_transport_error, _detail}} =
               Cobbler.request_plan(
                 goal.id,
                 PlannerHelpers.request_attrs(),
                 admitted(log, fixture: fixture)
               )

      assert Shoestring.Test.PlannerCallLog.count(log) == 1
      assert Cobbler.list_plan_revisions(goal.id) == []

      [request] = Cobbler.list_planner_requests(goal.id)
      assert request.status == "failed"
      assert request.error_kind == "transport_error"
    end

    test "a model refusal is terminal and distinct from transport", %{goal: goal, log: log} do
      fixture = %{errors: [{:refused, %{"reason" => "model_refused"}}]}

      assert {:error, {:planner_refused, _detail}} =
               Cobbler.request_plan(
                 goal.id,
                 PlannerHelpers.request_attrs(),
                 admitted(log, fixture: fixture)
               )

      assert Shoestring.Test.PlannerCallLog.count(log) == 1

      [request] = Cobbler.list_planner_requests(goal.id)
      assert request.status == "failed"
      assert request.error_kind == "refused"
    end
  end

  describe "idempotency and replay" do
    test "an identical duplicate replays without a new invocation", %{goal: goal, log: log} do
      attrs = PlannerHelpers.request_attrs()

      assert {:ok, %{revision: first, outcome: :recorded}} =
               Cobbler.request_plan(goal.id, attrs, admitted(log))

      assert {:ok, %{revision: second, outcome: :replayed, events: []}} =
               Cobbler.request_plan(goal.id, attrs, admitted(log))

      assert first.id == second.id
      assert Shoestring.Test.PlannerCallLog.count(log) == 1
      assert length(Cobbler.list_plan_revisions(goal.id)) == 1
    end

    test "the same id with different content is a conflict", %{goal: goal, log: log} do
      assert {:ok, _result} =
               Cobbler.request_plan(goal.id, PlannerHelpers.request_attrs(), admitted(log))

      conflicting =
        PlannerHelpers.request_attrs(goal_statement: "A completely different goal.")

      assert {:error, {:planner_request_conflict, detail}} =
               Cobbler.request_plan(goal.id, conflicting, admitted(log))

      assert detail["request_id"] == "plan-request-1"
      assert Shoestring.Test.PlannerCallLog.count(log) == 1
    end

    test "a terminal manual outcome replays without new invocations", %{goal: goal, log: log} do
      fixture = %{errors: [{:transport, %{"reason" => "timeout"}}]}
      attrs = PlannerHelpers.request_attrs()

      assert {:error, {:planner_transport_error, _detail}} =
               Cobbler.request_plan(goal.id, attrs, admitted(log, fixture: fixture))

      assert {:error, {:planner_transport_error, _detail}} =
               Cobbler.request_plan(goal.id, attrs, admitted(log, fixture: fixture))

      assert Shoestring.Test.PlannerCallLog.count(log) == 1
    end
  end

  describe "cancellation" do
    test "cancelling an in-progress request settles the accounting", %{goal: goal} do
      request =
        PlannerRequestRecord.claim_changeset(
          goal.id,
          %{
            request_id: "plan-request-hung",
            requested_by: "human:planner",
            planner_identity: "fixture-planner",
            planner_version: "1",
            planner_model: "fixture-1",
            input_digest: String.duplicate("a", 64),
            goal_statement: "A goal whose planner went quiet.",
            base_revision: PlanFixtures.base_revision(),
            proposal_id: "plan-request-hung"
          },
          PlannerHelpers.now()
        )
        |> Shoestring.Repo.insert!()

      assert {:ok, %{request: cancelled, outcome: :recorded, events: events}} =
               Cobbler.cancel_plan_request(
                 goal.id,
                 "plan-request-hung",
                 %{cancelled_by: "human:operator"}
               )

      assert cancelled.id == request.id
      assert cancelled.status == "cancelled"
      assert events != []
      assert event_types(goal, ["cobbler.planner.resolved"]) == 1

      # Cancelling again replays the settled state without touching it.
      assert {:ok, %{outcome: :replayed, events: []}} =
               Cobbler.cancel_plan_request(
                 goal.id,
                 "plan-request-hung",
                 %{cancelled_by: "human:operator"}
               )
    end

    test "cancelling an unknown request is not found", %{goal: goal} do
      assert {:error, :planner_request_not_found} =
               Cobbler.cancel_plan_request(goal.id, "no-such-request", %{
                 cancelled_by: "human:operator"
               })
    end

    test "cancelling requires a human identity", %{goal: goal} do
      assert {:error, {:non_human_identity, _detail}} =
               Cobbler.cancel_plan_request(goal.id, "plan-request-1", %{
                 cancelled_by: "planner:fixture"
               })
    end
  end

  describe "rebuild" do
    test "rebuild converges on the stored requests", %{goal: goal, log: log} do
      assert {:ok, _result} =
               Cobbler.request_plan(goal.id, PlannerHelpers.request_attrs(), admitted(log))

      blocked = opts(log, PlannerHelpers.blocked_snapshot())

      assert {:error, _reason} =
               Cobbler.request_plan(
                 goal.id,
                 PlannerHelpers.request_attrs(
                   request_id: "plan-request-blocked",
                   parent_revision_number: 1
                 ),
                 blocked
               )

      assert {:ok, %{requests: requests, consistent?: true, divergences: []}} =
               Cobbler.rebuild_planner(goal.id)

      assert length(requests) == 2
      assert Enum.map(requests, & &1["request_id"]) == ["plan-request-1", "plan-request-blocked"]
    end
  end

  describe "lineage checks" do
    test "a second goal revision needs its parent named", %{goal: goal, log: log} do
      assert {:ok, %{revision: _first}} =
               Cobbler.request_plan(goal.id, PlannerHelpers.request_attrs(), admitted(log))

      # The planner cannot silently branch: without a parent the request is
      # refused before any admission or invocation.
      assert {:error, {:invalid_planner_request, :parent_revision_number, _message}} =
               Cobbler.request_plan(
                 goal.id,
                 PlannerHelpers.request_attrs(request_id: "plan-request-2"),
                 admitted(log)
               )

      assert Shoestring.Test.PlannerCallLog.count(log) == 1

      assert {:ok, %{revision: second}} =
               Cobbler.request_plan(
                 goal.id,
                 PlannerHelpers.request_attrs(
                   request_id: "plan-request-2",
                   parent_revision_number: 1
                 ),
                 admitted(log)
               )

      assert second.revision_number == 2
    end
  end

  describe "review regressions" do
    test "an unconfigured production planner is refused with zero accounting", %{
      goal: goal,
      log: log
    } do
      unconfigured = opts(log, PlannerHelpers.admitted_snapshot(), adapter: PlannerHttp)

      assert {:error, :planner_not_configured} =
               Cobbler.request_plan(goal.id, PlannerHelpers.request_attrs(), unconfigured)

      # No claim, no admission, no invocation: configuration is checked
      # before anything is admitted or consumed.
      assert Cobbler.list_planner_requests(goal.id) == []
      assert event_types(goal, ["admission.decided"]) == 0
      assert event_types(goal, ["cobbler.planner.requested"]) == 0
      assert event_types(goal, ["cobbler.planner.resolved"]) == 0
      assert Cobbler.list_plan_revisions(goal.id) == []
      assert Shoestring.Test.PlannerCallLog.count(log) == 0
    end

    test "the same content from a different initiator is a conflict, not a replay", %{
      goal: goal,
      log: log
    } do
      assert {:ok, %{outcome: :recorded}} =
               Cobbler.request_plan(goal.id, PlannerHelpers.request_attrs(), admitted(log))

      second_initiator = PlannerHelpers.request_attrs(requested_by: "human:second")

      assert {:error, {:planner_request_conflict, detail}} =
               Cobbler.request_plan(goal.id, second_initiator, admitted(log))

      # The digest binds the initiator, so another human's identical bytes
      # cannot replay the first attribution — and the conflict invokes
      # nothing.
      assert detail["request_id"] == "plan-request-1"
      assert Shoestring.Test.PlannerCallLog.count(log) == 1
      assert length(Cobbler.list_plan_revisions(goal.id)) == 1
    end

    test "a plan answering a different goal or base is rejected, never persisted", %{
      goal: goal,
      log: log
    } do
      fixture = %{
        plans: [PlannerHelpers.mismatched_goal_plan(), PlannerHelpers.mismatched_goal_plan()]
      }

      assert {:error, {:planner_manual_required, detail}} =
               Cobbler.request_plan(
                 goal.id,
                 PlannerHelpers.request_attrs(),
                 admitted(log, fixture: fixture)
               )

      # Bounded like any contract failure: one repair, then the manual path.
      assert detail["attempts_used"] == 2
      assert detail["validation_errors"] != []
      assert Shoestring.Test.PlannerCallLog.count(log) == 2

      # Nothing answering another goal may persist or dispatch.
      assert Cobbler.list_plan_revisions(goal.id) == []
      assert Cobbler.plan_authority(goal.id) == nil
    end

    test "cancellation racing a valid proposal leaves no orphan revision", %{
      goal: goal,
      log: log
    } do
      canceller = fn event ->
        if event.type == "cobbler.plan.revision.created" do
          Cobbler.cancel_plan_request(goal.id, "plan-request-1", %{
            cancelled_by: "human:operator"
          })
        else
          :ok
        end
      end

      result =
        Cobbler.request_plan(
          goal.id,
          PlannerHelpers.request_attrs(),
          admitted(log) |> Keyword.put(:publish_fun, canceller)
        )

      case result do
        {:ok, %{request: request, revision: revision, outcome: :recorded}} ->
          # The proposal committed atomically with its settlement before the
          # cancellation could land: exactly one revision, fully settled.
          assert request.status == "proposed"
          assert revision.status == "proposed"
          assert length(Cobbler.list_plan_revisions(goal.id)) == 1

        {:error, {:planner_cancelled, _detail}} ->
          # The cancellation won: no revision and no proposal event may be
          # left behind for the cancelled request.
          assert Cobbler.list_plan_revisions(goal.id) == []
          assert event_types(goal, ["cobbler.plan.revision.created"]) == 0

          [request] = Cobbler.list_planner_requests(goal.id)
          assert request.status == "cancelled"
      end
    end
  end
end
