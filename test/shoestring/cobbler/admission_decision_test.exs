defmodule Shoestring.Cobbler.AdmissionDecisionTest do
  use ExUnit.Case, async: true

  alias Shoestring.Cobbler.{AdmissionDecision, AdmissionPolicy}
  alias Shoestring.Trajectory.EventRegistry

  @now ~U[2026-09-07 14:00:00.000000Z]
  @decision_id "01950000-0000-7000-8000-000000000001"
  @run_id "01950000-0000-7000-8000-000000000002"

  @valid_candidate %{
    provider_id: "codex",
    adapter_id: "codex_app_server",
    support_tier: :proactive,
    compatibility_state: :compatible
  }

  @valid_observation %{
    "snapshot_id" => "01950000-0000-7000-8000-000000000003",
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
        "used_percent" => 45.0,
        "reset_at" => "2026-09-07T18:00:00Z",
        "reason" => nil
      },
      %{
        "kind" => "weekly",
        "state" => "observed",
        "used_percent" => 60.0,
        "reset_at" => "2026-09-14T00:00:00Z",
        "reason" => nil
      }
    ]
  }

  @valid_bounds %{
    "response_budget" => 10,
    "tool_budget" => 25,
    "deadline" => "2026-09-07T14:05:00Z",
    "checkpoint_cadence" => 1,
    "reserves" => %{"response" => 1, "tool" => 1}
  }

  describe "new/1 and to_payload/1" do
    test "constructs and serializes an admission decision" do
      policy = AdmissionPolicy.default()

      attrs = %{
        version: 1,
        decision_id: @decision_id,
        run_id: @run_id,
        result: :admit,
        reason_code: "automatic_admission_eligible",
        explanation: "Candidate is eligible for automatic admission",
        requested_capability: "supervised_execution",
        candidate: @valid_candidate,
        scope: "account:default",
        observation: @valid_observation,
        policy: AdmissionPolicy.to_map(policy),
        proposed_bounds: @valid_bounds,
        reobservation_required: false,
        evaluated_at: @now
      }

      assert {:ok, decision} = AdmissionDecision.new(attrs)
      assert decision.result == :admit
      assert decision.decision_id == @decision_id
      assert decision.run_id == @run_id
      assert decision.reobservation_required == false

      payload = AdmissionDecision.to_payload(decision)
      assert is_map(payload)
      assert payload["result"] == "admit"
      assert payload["decision_id"] == @decision_id
      assert payload["run_id"] == @run_id
      assert payload["evaluated_at"] == "2026-09-07T14:00:00.000000Z"
      assert is_map(payload["observation"])
      assert is_map(payload["policy"])

      assert {:ok, roundtripped} = AdmissionDecision.from_payload(payload)
      assert roundtripped.decision_id == decision.decision_id
      assert roundtripped.result == decision.result
      assert roundtripped.reason_code == decision.reason_code
    end

    test "supports defer_until and reobservation_required for deferred decisions" do
      defer_time = ~U[2026-09-07 14:01:00.000000Z]

      attrs = %{
        decision_id: @decision_id,
        result: :defer_until,
        reason_code: "scope_occupied",
        explanation: "Scope occupied by active run",
        requested_capability: "supervised_execution",
        candidate: @valid_candidate,
        scope: "account:default",
        observation: @valid_observation,
        policy: AdmissionPolicy.to_map(AdmissionPolicy.default()),
        proposed_bounds: @valid_bounds,
        defer_until: defer_time,
        reobservation_required: true,
        evaluated_at: @now
      }

      assert {:ok, decision} = AdmissionDecision.new(attrs)
      assert decision.result == :defer_until
      assert decision.defer_until == defer_time
      assert decision.reobservation_required == true

      payload = AdmissionDecision.to_payload(decision)
      assert payload["result"] == "defer_until"
      assert payload["defer_until"] == "2026-09-07T14:01:00.000000Z"
      assert payload["reobservation_required"] == true
    end

    test "preserves unknown window evidence without manufacturing 0" do
      unknown_observation = %{
        "snapshot_id" => nil,
        "observed_at" => nil,
        "age_seconds" => nil,
        "confidence" => "none",
        "freshness" => "unknown",
        "capacity_state" => "unknown",
        "windows" => [
          %{
            "kind" => "five_hour",
            "state" => "unknown",
            "used_percent" => nil,
            "reason" => "missing_snapshot"
          }
        ]
      }

      attrs = %{
        decision_id: @decision_id,
        result: :require_confirmation,
        reason_code: "unknown_capacity",
        explanation: "Unknown capacity",
        requested_capability: "supervised_execution",
        candidate: @valid_candidate,
        scope: "account:default",
        observation: unknown_observation,
        policy: AdmissionPolicy.to_map(AdmissionPolicy.default()),
        proposed_bounds: @valid_bounds,
        reobservation_required: true,
        evaluated_at: @now
      }

      assert {:ok, decision} = AdmissionDecision.new(attrs)
      window = List.first(decision.observation["windows"])
      assert window["state"] == "unknown"
      assert window["used_percent"] == nil
      refute window["used_percent"] == 0
      refute window["used_percent"] == 0.0
    end

    test "rejects invalid result values" do
      attrs = %{
        decision_id: @decision_id,
        result: :invalid_result,
        reason_code: "test",
        explanation: "test",
        requested_capability: "supervised_execution",
        candidate: @valid_candidate,
        scope: "account:default",
        observation: @valid_observation,
        policy: AdmissionPolicy.to_map(AdmissionPolicy.default()),
        proposed_bounds: @valid_bounds,
        evaluated_at: @now
      }

      assert {:error, changeset} = AdmissionDecision.new(attrs)

      assert "must be one of admit, defer_until, require_confirmation, reject" in errors_on(
               changeset
             ).result
    end
  end

  describe "EventRegistry integration" do
    test "validates admission.decided v1 payload in EventRegistry" do
      policy = AdmissionPolicy.default()

      decision = %AdmissionDecision{
        version: 1,
        decision_id: @decision_id,
        run_id: @run_id,
        result: :admit,
        reason_code: "automatic_admission_eligible",
        explanation: "Candidate is eligible for automatic admission",
        requested_capability: "supervised_execution",
        candidate: @valid_candidate,
        scope: "account:default",
        observation: @valid_observation,
        policy: AdmissionPolicy.to_map(policy),
        proposed_bounds: @valid_bounds,
        reobservation_required: false,
        evaluated_at: @now,
        extensions: %{}
      }

      payload = AdmissionDecision.to_payload(decision)

      assert {:ok, validated} =
               EventRegistry.validate_payload("admission.decided", 1, payload)

      assert validated["decision_id"] == @decision_id
      assert validated["result"] == "admit"
      assert validated["reobservation_required"] == false
    end

    test "rejects invalid payload missing required fields in EventRegistry" do
      invalid_payload = %{"decision_id" => @decision_id}

      assert {:error, {:invalid_payload, "admission.decided", 1, changeset}} =
               EventRegistry.validate_payload("admission.decided", 1, invalid_payload)

      errors = errors_on(changeset)
      assert "can't be blank" in errors.result
      assert "can't be blank" in errors.reason_code
      assert "can't be blank" in errors.candidate
      assert "can't be blank" in errors.observation
    end

    test "rejects unknown fields in admission.decided v1 payload" do
      policy = AdmissionPolicy.default()

      decision = %AdmissionDecision{
        version: 1,
        decision_id: @decision_id,
        result: :admit,
        reason_code: "automatic_admission_eligible",
        explanation: "Eligible",
        requested_capability: "supervised_execution",
        candidate: @valid_candidate,
        scope: "account:default",
        observation: @valid_observation,
        policy: AdmissionPolicy.to_map(policy),
        proposed_bounds: @valid_bounds,
        reobservation_required: false,
        evaluated_at: @now,
        extensions: %{}
      }

      payload =
        decision
        |> AdmissionDecision.to_payload()
        |> Map.put("malicious_unregistered_field", "surprise")

      assert {:error, {:invalid_payload, "admission.decided", 1, changeset}} =
               EventRegistry.validate_payload("admission.decided", 1, payload)

      assert "contains unsupported fields" in errors_on(changeset).base
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
