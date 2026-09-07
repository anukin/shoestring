defmodule Shoestring.Cobbler.StateReplayTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.Cobbler
  alias Shoestring.Cobbler.{AdmissionDecision, AdmissionPolicy, Claim, Intent, StateReplay}
  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{Goal, TrajectoryEvent}

  setup do
    goal =
      %Goal{}
      |> Goal.changeset(%{"title" => "Replay Test Goal"})
      |> Ecto.Changeset.put_change(:owner_id, Ecto.UUID.generate())
      |> Repo.insert!()

    {:ok, _} =
      Trajectory.append(goal.id, %{
        "type" => "goal.created",
        "schema_version" => 1,
        "actor" => "test_operator",
        "payload" => %{"title" => "Replay Test Goal"}
      })

    policy = AdmissionPolicy.default()

    decision = %AdmissionDecision{
      version: 1,
      decision_id: Ecto.UUID.generate(),
      goal_id: goal.id,
      result: :admit,
      reason_code: "automatic_admission_eligible",
      explanation: "Within safe operational margins",
      requested_capability: "supervised_execution",
      candidate: %{
        provider_id: "codex",
        adapter_id: "codex_app_server",
        support_tier: :proactive,
        compatibility_state: :compatible
      },
      scope: "account:default",
      observation: %{
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
            "used_percent" => 35.0,
            "reset_at" => "2026-09-07T18:00:00Z",
            "reason" => nil
          }
        ]
      },
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

  describe "pure event replay" do
    test "replays submitted, claimed, needs_user, resumed, and completed events" do
      goal_id = Ecto.UUID.generate()
      intent_id = Ecto.UUID.generate()
      claim_id = Ecto.UUID.generate()
      decision_id = Ecto.UUID.generate()

      events = [
        %TrajectoryEvent{
          type: "cobbler.intent_submitted",
          sequence: 1,
          payload: %{
            "command_id" => "cmd-1",
            "intent_id" => intent_id,
            "goal_id" => goal_id,
            "title" => "Pure Replay Task",
            "requested_capability" => "supervised_execution",
            "provider_id" => "codex",
            "scope" => "account:default",
            "admission_decision_id" => decision_id,
            "proposed_bounds" => %{"response_budget" => 10}
          }
        },
        %TrajectoryEvent{
          type: "cobbler.intent_claimed",
          sequence: 2,
          payload: %{
            "command_id" => "cmd-2",
            "intent_id" => intent_id,
            "claim_id" => claim_id,
            "goal_id" => goal_id,
            "provider_id" => "codex",
            "scope" => "account:default",
            "claimed_at" => "2026-09-07T14:01:00Z"
          }
        }
      ]

      assert {:ok, state} = StateReplay.replay_events(events)
      assert Map.has_key?(state.intents, intent_id)
      assert state.intents[intent_id].status == "active"
      assert state.active_claim != nil
      assert state.active_claim.intent_id == intent_id

      # Transition to needs_user
      events2 =
        events ++
          [
            %TrajectoryEvent{
              type: "cobbler.intent_transitioned",
              sequence: 3,
              payload: %{
                "command_id" => "cmd-3",
                "intent_id" => intent_id,
                "goal_id" => goal_id,
                "from_status" => "active",
                "to_status" => "needs_user",
                "event_name" => "needs_user"
              }
            }
          ]

      assert {:ok, state2} = StateReplay.replay_events(events2)
      assert state2.intents[intent_id].status == "needs_user"

      # Transition back via resume
      events3 =
        events2 ++
          [
            %TrajectoryEvent{
              type: "cobbler.intent_transitioned",
              sequence: 4,
              payload: %{
                "command_id" => "cmd-4",
                "intent_id" => intent_id,
                "goal_id" => goal_id,
                "from_status" => "needs_user",
                "to_status" => "active",
                "event_name" => "resume"
              }
            }
          ]

      assert {:ok, state3} = StateReplay.replay_events(events3)
      assert state3.intents[intent_id].status == "active"

      # Terminal completion releases active claim
      events4 =
        events3 ++
          [
            %TrajectoryEvent{
              type: "cobbler.intent_transitioned",
              sequence: 5,
              payload: %{
                "command_id" => "cmd-5",
                "intent_id" => intent_id,
                "goal_id" => goal_id,
                "from_status" => "active",
                "to_status" => "completed",
                "event_name" => "complete"
              }
            }
          ]

      assert {:ok, state4} = StateReplay.replay_events(events4)
      assert state4.intents[intent_id].status == "completed"
      assert state4.active_claim == nil
    end
  end

  describe "database rebuild from trajectory" do
    test "reconstructs database rows from canonical trajectory events", %{
      goal: goal,
      decision: decision
    } do
      payload = %{
        "title" => "Durable Trajectory Task",
        "requested_capability" => "supervised_execution",
        "provider_id" => "codex",
        "scope" => "account:default",
        "admission_decision" => AdmissionDecision.to_payload(decision)
      }

      {:ok, %{intent_id: intent_id}} = Cobbler.submit_intent(goal.id, "cmd-sub", payload)
      {:ok, %{claim_id: claim_id}} = Cobbler.claim_intent(goal.id, "cmd-clm", intent_id)

      # Verify initial database state
      assert Repo.get(Intent, intent_id) != nil
      assert Repo.get(Claim, claim_id) != nil

      # Delete database projection rows directly to simulate loss / cold restart
      Repo.delete_all(Claim)
      Repo.delete_all(Intent)

      assert Repo.get(Intent, intent_id) == nil
      assert Repo.get(Claim, claim_id) == nil

      # Rebuild from canonical trajectory
      assert {:ok, %{intents: rebuilt_intents, active_claim: rebuilt_claim}} =
               StateReplay.rebuild(goal.id)

      assert length(rebuilt_intents) == 1
      rebuilt_intent = hd(rebuilt_intents)
      assert rebuilt_intent.id == intent_id
      assert rebuilt_intent.status == "active"
      assert rebuilt_intent.title == "Durable Trajectory Task"

      assert rebuilt_claim != nil
      assert rebuilt_claim.id == claim_id
      assert rebuilt_claim.status == "active"
      assert rebuilt_claim.intent_id == intent_id

      # Verify Cobbler.replay_state matches
      assert {:ok, in_memory} = Cobbler.replay_state(goal.id)
      assert in_memory.intents[intent_id].status == "active"
      assert in_memory.active_claim.id == claim_id
    end
  end
end
