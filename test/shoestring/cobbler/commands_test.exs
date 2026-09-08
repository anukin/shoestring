defmodule Shoestring.Cobbler.CommandsTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.Cobbler
  alias Shoestring.Cobbler.{AdmissionDecision, AdmissionPolicy}
  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.Goal

  setup do
    goal =
      %Goal{}
      |> Goal.changeset(%{"title" => "Cobbler Commands Test Goal"})
      |> Ecto.Changeset.put_change(:owner_id, Ecto.UUID.generate())
      |> Repo.insert!()

    # Create goal.created event in trajectory
    {:ok, _} =
      Trajectory.append(goal.id, %{
        "type" => "goal.created",
        "schema_version" => 1,
        "actor" => "test_operator",
        "payload" => %{"title" => "Cobbler Commands Test Goal"}
      })

    policy = AdmissionPolicy.default()

    valid_candidate = %{
      provider_id: "codex",
      adapter_id: "codex_app_server",
      support_tier: :proactive,
      compatibility_state: :compatible
    }

    valid_observation = %{
      "snapshot_id" => Ecto.UUID.generate(),
      "observed_at" => "2026-09-07T13:58:00Z",
      "expires_at" => "2026-09-07T14:03:00Z",
      "age_seconds" => 120,
      "confidence" => "high",
      "freshness" => "fresh",
      "capacity_state" => "observed",
      "windows" => [
        %{
          "kind" => "five_hour",
          "state" => "observed",
          "used_percent" => 40.0,
          "reset_at" => "2026-09-07T18:00:00Z",
          "reason" => nil
        }
      ]
    }

    decision = %AdmissionDecision{
      version: 1,
      decision_id: Ecto.UUID.generate(),
      goal_id: goal.id,
      result: :admit,
      reason_code: "automatic_admission_eligible",
      explanation: "Within safe operational margins",
      requested_capability: "supervised_execution",
      candidate: valid_candidate,
      scope: "account:default",
      observation: valid_observation,
      policy: AdmissionPolicy.to_map(policy),
      proposed_bounds: %{
        "response_budget" => 10,
        "tool_budget" => 25,
        "deadline" => "2026-09-07T15:00:00Z",
        "checkpoint_cadence" => 1,
        "reserves" => %{"response" => 1, "tool" => 1}
      },
      reobservation_required: false,
      evaluated_at: ~U[2026-09-07 14:00:00Z]
    }

    %{goal: goal, decision: decision}
  end

  describe "submit_intent" do
    test "creates inert pending intent and emits cobbler.intent_submitted event", %{
      goal: goal,
      decision: decision
    } do
      payload = %{
        "title" => "Implement Feature X",
        "requested_capability" => "supervised_execution",
        "provider_id" => "codex",
        "scope" => "account:default",
        "admission_decision" => AdmissionDecision.to_payload(decision)
      }

      assert {:ok, result} = Cobbler.submit_intent(goal.id, "cmd-submit-1", payload)
      assert result.status == "pending"
      assert result.provider_id == "codex"
      assert result.scope == "account:default"

      # Verify persisted intent in database
      intent = Cobbler.get_intent(result.intent_id)
      assert intent != nil
      assert intent.status == "pending"
      assert intent.title == "Implement Feature X"
      assert intent.admission_decision_id == decision.decision_id

      # Execution is completely disabled: intent is inert
      assert Cobbler.get_active_claim() == nil

      # Verify authoritative trajectory event
      assert {:ok, events} = Trajectory.replay(goal.id)
      submitted_event = Enum.find(events, &(&1.type == "cobbler.intent_submitted"))
      assert submitted_event != nil
      assert submitted_event.payload["command_id"] == "cmd-submit-1"
      assert submitted_event.payload["intent_id"] == intent.id
      assert submitted_event.payload["admission_decision_id"] == decision.decision_id
    end

    test "caller-supplied command ID is scoped to goal", %{goal: goal, decision: decision} do
      goal2 =
        %Goal{}
        |> Goal.changeset(%{"title" => "Second Goal"})
        |> Ecto.Changeset.put_change(:owner_id, Ecto.UUID.generate())
        |> Repo.insert!()

      {:ok, _} =
        Trajectory.append(goal2.id, %{
          "type" => "goal.created",
          "schema_version" => 1,
          "actor" => "test_operator",
          "payload" => %{"title" => "Second Goal"}
        })

      payload1 = %{
        "title" => "Intent Goal 1",
        "requested_capability" => "supervised_execution",
        "provider_id" => "codex",
        "scope" => "account:default",
        "admission_decision" => AdmissionDecision.to_payload(decision)
      }

      decision2 = %{decision | goal_id: goal2.id, decision_id: Ecto.UUID.generate()}

      payload2 = %{
        "title" => "Intent Goal 2",
        "requested_capability" => "supervised_execution",
        "provider_id" => "codex",
        "scope" => "account:default",
        "admission_decision" => AdmissionDecision.to_payload(decision2)
      }

      # Same command_id under two different goals succeeds independently
      assert {:ok, res1} = Cobbler.submit_intent(goal.id, "cmd-shared-id", payload1)
      assert {:ok, res2} = Cobbler.submit_intent(goal2.id, "cmd-shared-id", payload2)
      assert res1.intent_id != res2.intent_id
    end

    test "replaying identical command returns original result without new events", %{
      goal: goal,
      decision: decision
    } do
      payload = %{
        "title" => "Idempotent Intent",
        "requested_capability" => "supervised_execution",
        "provider_id" => "codex",
        "scope" => "account:default",
        "admission_decision" => AdmissionDecision.to_payload(decision)
      }

      assert {:ok, first_result} = Cobbler.submit_intent(goal.id, "cmd-idemp-1", payload)

      {:ok, events_after_first} = Trajectory.replay(goal.id)
      count_first = length(events_after_first)

      # Re-execute exact command
      assert {:ok, second_result} = Cobbler.submit_intent(goal.id, "cmd-idemp-1", payload)
      assert second_result["intent_id"] == first_result.intent_id

      # Zero new events emitted
      {:ok, events_after_second} = Trajectory.replay(goal.id)
      assert length(events_after_second) == count_first

      # Intent table count untouched
      assert length(Cobbler.list_intents(goal.id)) == 1
    end

    test "reusing command_id with conflicting payload is rejected", %{
      goal: goal,
      decision: decision
    } do
      payload1 = %{
        "title" => "Original Intent",
        "requested_capability" => "supervised_execution",
        "provider_id" => "codex",
        "scope" => "account:default",
        "admission_decision" => AdmissionDecision.to_payload(decision)
      }

      assert {:ok, _} = Cobbler.submit_intent(goal.id, "cmd-conflict-1", payload1)

      payload2 = %{
        "title" => "Conflicting Intent with Different Title",
        "requested_capability" => "supervised_execution",
        "provider_id" => "codex",
        "scope" => "account:default",
        "admission_decision" => AdmissionDecision.to_payload(decision)
      }

      assert {:error, {:conflicting_command_payload, msg}} =
               Cobbler.submit_intent(goal.id, "cmd-conflict-1", payload2)

      assert msg =~ "was already executed with a different payload"
    end
  end

  describe "admission reference validation (unbypassable)" do
    test "rejects admission decisions that are not :admit", %{goal: goal, decision: decision} do
      rejected_decision = %{decision | result: :reject, reason_code: "unsupported_capability"}

      payload = %{
        "title" => "Bypass Attempt",
        "requested_capability" => "supervised_execution",
        "provider_id" => "codex",
        "scope" => "account:default",
        "admission_decision" => AdmissionDecision.to_payload(rejected_decision)
      }

      assert {:error, {:admission_not_admitted, msg}} =
               Cobbler.submit_intent(goal.id, "cmd-reject-ref", payload)

      assert msg =~ "only :admit is permitted"

      deferred_decision = %{
        decision
        | result: :defer_until,
          reason_code: "reserve_breach_five_hour"
      }

      payload_deferred = %{
        payload
        | "admission_decision" => AdmissionDecision.to_payload(deferred_decision)
      }

      assert {:error, {:admission_not_admitted, _}} =
               Cobbler.submit_intent(goal.id, "cmd-defer-ref", payload_deferred)
    end

    test "rejects provider mismatch between decision and intent", %{
      goal: goal,
      decision: decision
    } do
      payload = %{
        "title" => "Mismatch Provider",
        "requested_capability" => "supervised_execution",
        "provider_id" => "claude",
        "scope" => "account:default",
        "admission_decision" => AdmissionDecision.to_payload(decision)
      }

      assert {:error, {:admission_provider_mismatch, msg}} =
               Cobbler.submit_intent(goal.id, "cmd-prov-mismatch", payload)

      assert msg =~ "does not match requested 'claude'"
    end

    test "rejects capability mismatch between decision and intent", %{
      goal: goal,
      decision: decision
    } do
      payload = %{
        "title" => "Mismatch Capability",
        "requested_capability" => "autonomous_agent",
        "provider_id" => "codex",
        "scope" => "account:default",
        "admission_decision" => AdmissionDecision.to_payload(decision)
      }

      assert {:error, {:admission_capability_mismatch, _}} =
               Cobbler.submit_intent(goal.id, "cmd-cap-mismatch", payload)
    end

    test "rejects scope mismatch between decision and intent", %{goal: goal, decision: decision} do
      payload = %{
        "title" => "Mismatch Scope",
        "requested_capability" => "supervised_execution",
        "provider_id" => "codex",
        "scope" => "account:restricted_org",
        "admission_decision" => AdmissionDecision.to_payload(decision)
      }

      assert {:error, {:admission_scope_mismatch, _}} =
               Cobbler.submit_intent(goal.id, "cmd-scope-mismatch", payload)
    end

    test "rejects arbitrary invalid admission payload", %{goal: goal} do
      payload = %{
        "title" => "Fake Admit",
        "requested_capability" => "supervised_execution",
        "provider_id" => "codex",
        "scope" => "account:default",
        "admission_decision" => %{"result" => "admit", "fake_field" => "bogus"}
      }

      assert {:error, {:invalid_admission_decision, _}} =
               Cobbler.submit_intent(goal.id, "cmd-fake-admit", payload)
    end
  end

  describe "claim_intent and global SQLite exclusivity" do
    setup %{goal: goal, decision: decision} do
      payload = %{
        "title" => "Task to Claim",
        "requested_capability" => "supervised_execution",
        "provider_id" => "codex",
        "scope" => "account:default",
        "admission_decision" => AdmissionDecision.to_payload(decision)
      }

      {:ok, intent_res} = Cobbler.submit_intent(goal.id, "cmd-submit-claimable", payload)
      %{intent_id: intent_res.intent_id}
    end

    test "claims pending intent and asserts global active claim", %{
      goal: goal,
      intent_id: intent_id
    } do
      assert {:ok, claim_res} = Cobbler.claim_intent(goal.id, "cmd-claim-intent", intent_id)
      assert claim_res.status == "active"
      assert claim_res.intent_id == intent_id

      intent = Cobbler.get_intent(intent_id)
      assert intent.status == "active"

      active_claim = Cobbler.get_active_claim()
      assert active_claim != nil
      assert active_claim.intent_id == intent_id
      assert active_claim.active_slot == "global"

      # Trajectory event emitted
      {:ok, events} = Trajectory.replay(goal.id)
      claimed_event = Enum.find(events, &(&1.type == "cobbler.intent_claimed"))
      assert claimed_event != nil
      assert claimed_event.payload["intent_id"] == intent_id
      assert claimed_event.payload["claim_id"] == claim_res.claim_id
    end

    test "competing intent cannot claim while one is active (SQLite unique constraint)", %{
      goal: goal,
      decision: decision,
      intent_id: intent_id1
    } do
      # Submit second intent
      payload2 = %{
        "title" => "Competing Task",
        "requested_capability" => "supervised_execution",
        "provider_id" => "codex",
        "scope" => "account:default",
        "admission_decision" =>
          AdmissionDecision.to_payload(%{decision | decision_id: Ecto.UUID.generate()})
      }

      {:ok, %{intent_id: intent_id2}} =
        Cobbler.submit_intent(goal.id, "cmd-submit-competing", payload2)

      # First claim succeeds
      assert {:ok, _} = Cobbler.claim_intent(goal.id, "cmd-claim-first", intent_id1)

      # Second claim fails
      assert {:error, {:already_claimed, current_claim}} =
               Cobbler.claim_intent(goal.id, "cmd-claim-second", intent_id2)

      assert current_claim.intent_id == intent_id1
      assert current_claim.status == "active"

      # Second intent remains inert pending
      assert Cobbler.get_intent(intent_id2).status == "pending"
    end

    test "replaying claim with same command recovers existing claim", %{
      goal: goal,
      intent_id: intent_id
    } do
      assert {:ok, first} = Cobbler.claim_intent(goal.id, "cmd-claim-repeat", intent_id)
      assert {:ok, second} = Cobbler.claim_intent(goal.id, "cmd-claim-repeat", intent_id)

      assert first.claim_id == second["claim_id"]
    end
  end

  describe "lifecycle state machine transitions" do
    setup %{goal: goal, decision: decision} do
      payload = %{
        "title" => "Lifecycle Task",
        "requested_capability" => "supervised_execution",
        "provider_id" => "codex",
        "scope" => "account:default",
        "admission_decision" => AdmissionDecision.to_payload(decision)
      }

      {:ok, %{intent_id: intent_id}} = Cobbler.submit_intent(goal.id, "cmd-submit-lc", payload)
      {:ok, _} = Cobbler.claim_intent(goal.id, "cmd-claim-lc", intent_id)
      %{intent_id: intent_id}
    end

    test "needs_user is recoverable via resume", %{goal: goal, intent_id: intent_id} do
      assert {:ok, res1} =
               Cobbler.request_user(goal.id, "cmd-need-user", intent_id, "Missing OAuth token")

      assert res1.status == "needs_user"
      assert Cobbler.get_intent(intent_id).status == "needs_user"

      # Recoverable! Resume brings it back to active
      assert {:ok, res2} = Cobbler.resume_intent(goal.id, "cmd-resume", intent_id)
      assert res2.status == "active"
      assert Cobbler.get_intent(intent_id).status == "active"
    end

    test "complete transitions to terminal and releases exclusive claim", %{
      goal: goal,
      intent_id: intent_id
    } do
      assert {:ok, res} = Cobbler.complete_intent(goal.id, "cmd-complete", intent_id, "Success")
      assert res.status == "completed"

      # Intent is completed
      assert Cobbler.get_intent(intent_id).status == "completed"

      # Exclusive claim is RELEASED
      assert Cobbler.get_active_claim() == nil

      # Completed intent rejects further transitions
      assert {:error, {:illegal_transition, :completed, :needs_user}} =
               Cobbler.request_user(goal.id, "cmd-post-complete", intent_id, "Try again")
    end

    test "fail transitions to terminal and releases exclusive claim", %{
      goal: goal,
      intent_id: intent_id
    } do
      assert {:ok, res} =
               Cobbler.fail_intent(goal.id, "cmd-fail", intent_id, "Fatal network error")

      assert res.status == "failed"

      assert Cobbler.get_intent(intent_id).status == "failed"
      assert Cobbler.get_active_claim() == nil

      # Failed intent rejects transitions
      assert {:error, {:illegal_transition, :failed, :resume}} =
               Cobbler.resume_intent(goal.id, "cmd-post-fail", intent_id)
    end

    test "cancel transitions to terminal and releases exclusive claim", %{
      goal: goal,
      intent_id: intent_id
    } do
      assert {:ok, res} =
               Cobbler.cancel_intent(goal.id, "cmd-cancel", intent_id, "User requested")

      assert res.status == "cancelled"

      assert Cobbler.get_intent(intent_id).status == "cancelled"
      assert Cobbler.get_active_claim() == nil

      # Cancelled intent rejects transitions
      assert {:error, {:illegal_transition, :cancelled, :complete}} =
               Cobbler.complete_intent(goal.id, "cmd-post-cancel", intent_id)
    end
  end
end
