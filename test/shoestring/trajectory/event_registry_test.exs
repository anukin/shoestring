defmodule Shoestring.Trajectory.EventRegistryTest do
  use ExUnit.Case, async: true

  alias Shoestring.Trajectory.{EventEnvelope, EventRegistry}

  @valid_envelope %{
    "goal_id" => "11111111-1111-4111-8111-111111111111",
    "sequence" => 1,
    "type" => "decision.recorded",
    "actor" => "system",
    "occurred_at" => "2026-08-29T12:00:00.123456Z",
    "schema_version" => 1,
    "payload" => %{"decision" => "continue"}
  }

  @now ~U[2026-08-30 12:00:00Z]

  test "the registry exposes initial and harness v1 event types" do
    registered = EventRegistry.registered_types()

    assert [
             {"decision.recorded", 1},
             {"goal.created", 1},
             {"task.completed", 1},
             {"task.created", 1}
           ] -- registered == []

    assert [
             {"run.requested", 1},
             {"run.starting", 1},
             {"run.running", 1},
             {"run.pausing", 1},
             {"run.suspended", 1},
             {"run.completed", 1},
             {"run.failed", 1},
             {"run.cancelling", 1},
             {"run.cancelled", 1},
             {"lease.proposed", 1},
             {"lease.granted", 1},
             {"lease.active", 1},
             {"lease.renewal_due", 1},
             {"lease.renewed", 1},
             {"lease.expired", 1},
             {"lease.revoked", 1},
             {"lease.checkpoint_required", 1},
             {"checkpoint.created", 1},
             {"capacity.snapshot_observed", 1},
             {"capacity.snapshot_observed", 2},
             {"harness.event_recorded", 1}
           ] -- registered == []

    assert [
             {"dispatch.effect_deferred", 1},
             {"dispatch.effect_failed", 1},
             {"dispatch.effect_unknown", 1},
             {"dispatch.requested", 1}
           ] -- registered == []
  end

  test "registered harness payloads retain exact version compatibility" do
    run_id = "11111111-1111-4111-8111-111111111111"

    assert {:ok, %{"run_id" => ^run_id}} =
             EventRegistry.validate_payload("run.starting", 1, %{"run_id" => run_id})

    assert {:error, {:unknown_event_version, "run.starting", 2}} =
             EventRegistry.validate_payload("run.starting", 2, %{"run_id" => run_id})

    assert {:error, {:invalid_payload, "run.failed", 1, changeset}} =
             EventRegistry.validate_payload("run.failed", 1, %{"run_id" => run_id})

    assert "can't be blank" in errors_on(changeset).error_category
  end

  test "dispatch outcome events require only their safe persisted identity" do
    payload = %{
      "dispatch_id" => "11111111-1111-4111-8111-111111111111",
      "run_id" => "22222222-2222-4222-8222-222222222222",
      "error_code" => "effect_unknown"
    }

    for type <- ["dispatch.effect_deferred", "dispatch.effect_failed", "dispatch.effect_unknown"] do
      assert {:ok, ^payload} = EventRegistry.validate_payload(type, 1, payload)

      assert {:error, {:invalid_payload, ^type, 1, _}} =
               EventRegistry.validate_payload(type, 1, Map.delete(payload, "error_code"))
    end
  end

  test "all four v1 event types validate their payloads independently" do
    valid_payloads = [
      {"goal.created", %{"title" => "Ship it"}},
      {"task.created",
       %{"task_id" => "22222222-2222-4222-8222-222222222222", "title" => "Test it"}},
      {"decision.recorded", %{"decision" => "Use SQLite"}},
      {"task.completed", %{"task_id" => "22222222-2222-4222-8222-222222222222"}}
    ]

    for {type, payload} <- valid_payloads do
      assert {:ok, ^payload} = EventRegistry.validate_payload(type, 1, payload)
    end
  end

  test "envelope validation is separate from payload validation" do
    assert {:ok, envelope} = EventEnvelope.validate(@valid_envelope)
    assert envelope.type == "decision.recorded"

    assert {:ok, %{"decision" => "continue"}} =
             EventRegistry.validate_payload(
               envelope.type,
               envelope.schema_version,
               envelope.payload
             )
  end

  test "malformed envelopes return a stable changeset error" do
    assert {:error, {:invalid_envelope, changeset}} =
             EventRegistry.validate(Map.delete(@valid_envelope, "actor"))

    assert "can't be blank" in errors_on(changeset).actor
  end

  test "a non-map envelope returns the stable base must-be-a-map error" do
    assert {:error, changeset} = EventEnvelope.validate(:not_an_envelope)
    assert "must be a map" in errors_on(changeset).base
  end

  test "malformed payloads return a stable payload changeset error" do
    assert {:error, {:invalid_payload, "task.created", 1, changeset}} =
             EventRegistry.validate_payload("task.created", 1, %{"task_id" => "not-a-uuid"})

    assert "must be a UUID" in errors_on(changeset).task_id
  end

  test "unknown fields are rejected for strict schemas and explicitly additive v2 is sanitized" do
    assert {:error, {:invalid_payload, "decision.recorded", 1, changeset}} =
             EventRegistry.validate_payload("decision.recorded", 1, %{
               "decision" => "continue",
               "linkage_typo" => "ignored"
             })

    assert "contains unsupported fields" in errors_on(changeset).base

    {:ok, legacy} =
      EventRegistry.upcast("capacity.snapshot_observed", 1, legacy_capacity_payload())

    additive =
      legacy
      |> Map.put("future_field", "ignored")
      |> put_in(["source", "future_field"], "ignored")
      |> put_in(["windows", "items", Access.at(0), "future_field"], "ignored")

    assert {:ok, sanitized} =
             EventRegistry.validate_payload("capacity.snapshot_observed", 2, additive, now: @now)

    refute Map.has_key?(sanitized, "future_field")
    refute Map.has_key?(sanitized["source"], "future_field")
    refute Map.has_key?(hd(sanitized["windows"]["items"]), "future_field")
  end

  test "additive v2 fields remain secret-scanned without echoing their values" do
    {:ok, legacy} =
      EventRegistry.upcast("capacity.snapshot_observed", 1, legacy_capacity_payload())

    payload = Map.put(legacy, "future_field", "api_key: sentinel-value")

    assert {:error, {:invalid_payload, "capacity.snapshot_observed", 2, changeset}} =
             EventRegistry.validate_payload("capacity.snapshot_observed", 2, payload, now: @now)

    refute inspect(errors_on(changeset)) =~ "sentinel-value"
  end

  test "unknown event types and versions are rejected without atomizing input" do
    unknown_type = "future.#{System.unique_integer([:positive])}"

    assert {:error, {:unknown_event_type, ^unknown_type}} =
             EventRegistry.validate_payload(unknown_type, 1, %{})

    assert {:error, {:unknown_event_type, ^unknown_type}} =
             EventRegistry.validate(Map.put(@valid_envelope, "type", unknown_type))

    assert {:error, {:unknown_event_version, "decision.recorded", 99}} =
             EventRegistry.validate_payload("decision.recorded", 99, %{})

    assert {:error, {:unknown_event_version, "decision.recorded", 99}} =
             EventRegistry.validate(Map.put(@valid_envelope, "schema_version", 99))
  end

  test "current versions and identity upcasts are explicit" do
    payload = %{"decision" => "continue", "artifact_id" => Ecto.UUID.generate()}

    assert EventRegistry.current_version("decision.recorded") == 1
    assert {:ok, ^payload} = EventRegistry.upcast("decision.recorded", 1, payload)

    assert {:error, {:unknown_event_type, "future.event"}} =
             EventRegistry.current_version("future.event")

    assert {:error, {:unknown_event_version, "decision.recorded", 2}} =
             EventRegistry.upcast("decision.recorded", 2, payload)

    assert EventRegistry.current_version("capacity.snapshot_observed") == 2
  end

  test "legacy capacity event states remain compatible and upcast into fail-closed v2 metadata" do
    payload = legacy_capacity_payload()

    assert {:ok, ^payload} =
             EventRegistry.validate_payload("capacity.snapshot_observed", 1, payload)

    assert {:ok, upcast} =
             EventRegistry.upcast("capacity.snapshot_observed", 1, payload, now: @now)

    assert upcast["contract_version"] == 2
    assert upcast["capacity_state"] == "degraded"
    assert upcast["source"]["provider_id"] == "legacy"
    assert upcast["source"]["invocation_mode"] == "unknown"
    assert upcast["source"]["event"] == "none"
    assert upcast["support_tier"] == "conservative_partial"
    assert upcast["compatibility_state"] == "degraded"
    assert upcast["reason"] == "legacy_capacity_contract_missing_provenance"

    for malformed <- [
          put_in(payload, ["capacity_state"], "available"),
          put_in(payload, ["windows", "items", Access.at(0), "state"], "observed"),
          put_in(payload, ["support_tier"], "proactive")
        ] do
      assert {:error, {:invalid_payload, "capacity.snapshot_observed", 1, _changeset}} =
               EventRegistry.validate_payload("capacity.snapshot_observed", 1, malformed,
                 now: @now
               )
    end
  end

  test "new legacy payloads are strict while stored legacy replay stays compatible" do
    payload =
      legacy_capacity_payload()
      |> Map.put("future_field", "ignored")
      |> put_in(["windows", "future_window_metadata"], %{"version" => 3})
      |> put_in(["windows", "items", Access.at(0), "future_field"], "ignored")
      |> put_in(["source", "future_field"], "ignored")

    assert {:error, {:invalid_payload, "capacity.snapshot_observed", 1, changeset}} =
             EventRegistry.validate_payload("capacity.snapshot_observed", 1, payload, now: @now)

    assert "contains unsupported fields" in errors_on(changeset).base

    nested_payload = Map.delete(payload, "future_field")

    assert {:error, {:invalid_payload, "capacity.snapshot_observed", 1, nested_changeset}} =
             EventRegistry.validate_payload("capacity.snapshot_observed", 1, nested_payload,
               now: @now
             )

    assert "must use a valid legacy windows format" in errors_on(nested_changeset).windows

    assert {:ok, validated} =
             EventRegistry.validate_payload("capacity.snapshot_observed", 1, nested_payload,
               now: @now,
               allow_legacy_unknown: true
             )

    refute Map.has_key?(validated["windows"], "future_window_metadata")

    replay_payload = Map.put(nested_payload, "historical_typo", "ignored")

    replay_envelope =
      Map.merge(@valid_envelope, %{
        "type" => "capacity.snapshot_observed",
        "payload" => replay_payload
      })

    assert {:ok, %{payload: replay_validated}} = EventRegistry.validate(replay_envelope)
    refute Map.has_key?(replay_validated, "historical_typo")
    refute Map.has_key?(replay_validated["windows"], "future_window_metadata")

    assert {:error, {:invalid_payload, "capacity.snapshot_observed", 1, _changeset}} =
             EventRegistry.validate_payload(
               "capacity.snapshot_observed",
               1,
               Map.delete(payload, "observed_at"),
               now: @now
             )
  end

  test "legacy observations after the event are upcast to deterministic unknown capacity" do
    payload =
      legacy_capacity_payload()
      |> Map.put("observed_at", "2026-08-30T12:00:01Z")

    assert {:ok, upcast} =
             EventRegistry.upcast("capacity.snapshot_observed", 1, payload, now: @now)

    assert upcast["capacity_state"] == "unknown"
    assert upcast["confidence"] == "none"
    assert upcast["reason"] == "legacy_capacity_observation_after_event"

    assert upcast["windows"]["items"] == [
             %{
               "kind" => "five_hour",
               "state" => "unknown",
               "reason" => "legacy_capacity_observation_after_event"
             }
           ]

    assert {:ok, _snapshot} =
             EventRegistry.validate_payload("capacity.snapshot_observed", 2, upcast, now: @now)
  end

  test "legacy capacity upcast produces a v2-valid payload across the full legacy matrix" do
    window_shapes = %{
      all_observed: %{
        "items" => [%{"kind" => "five_hour", "state" => "known", "used_percent" => 25.0}]
      },
      all_unknown: %{
        "items" => [%{"kind" => "five_hour", "state" => "unknown", "reason" => "probe_failed"}]
      },
      mixed: %{
        "items" => [
          %{"kind" => "five_hour", "state" => "known", "used_percent" => 25.0},
          %{"kind" => "weekly", "state" => "unknown", "reason" => "probe_failed"}
        ]
      }
    }

    for confidence <- ["none", "low", "medium", "high"],
        {shape_name, windows} <- window_shapes do
      payload =
        legacy_capacity_payload()
        |> Map.put("confidence", confidence)
        |> Map.put("windows", windows)

      assert {:ok, ^payload} =
               EventRegistry.validate_payload("capacity.snapshot_observed", 1, payload, now: @now),
             "legacy known/#{confidence}/#{shape_name} should be a valid v1 payload"

      assert {:ok, upcast} =
               EventRegistry.upcast("capacity.snapshot_observed", 1, payload, now: @now)

      assert {:ok, _snapshot} =
               EventRegistry.validate_payload("capacity.snapshot_observed", 2, upcast, now: @now),
             "legacy known/#{confidence}/#{shape_name} upcast to #{inspect(upcast)} is not v2-valid"

      case shape_name do
        shape when shape in [:all_observed, :mixed] ->
          assert upcast["capacity_state"] == "degraded"
          assert upcast["confidence"] in ["low", "medium", "high"]

        :all_unknown ->
          assert upcast["capacity_state"] == "unknown"
          assert upcast["confidence"] == "none"
      end
    end

    unknown_payload =
      legacy_capacity_payload()
      |> Map.put("capacity_state", "unknown")
      |> Map.put("windows", %{"items" => []})
      |> Map.put("confidence", "none")

    assert {:ok, ^unknown_payload} =
             EventRegistry.validate_payload("capacity.snapshot_observed", 1, unknown_payload,
               now: @now
             )

    assert {:ok, upcast} =
             EventRegistry.upcast("capacity.snapshot_observed", 1, unknown_payload, now: @now)

    assert upcast["capacity_state"] == "unknown"
    assert upcast["confidence"] == "none"

    assert {:ok, _snapshot} =
             EventRegistry.validate_payload("capacity.snapshot_observed", 2, upcast, now: @now)
  end

  test "capacity required fields and unregistered versions remain visible failures" do
    assert {:ok, payload} =
             EventRegistry.upcast("capacity.snapshot_observed", 1, legacy_capacity_payload(),
               now: @now
             )

    assert {:error, {:invalid_payload, "capacity.snapshot_observed", 2, changeset}} =
             EventRegistry.validate_payload(
               "capacity.snapshot_observed",
               2,
               Map.delete(payload, "freshness"),
               now: @now
             )

    assert "can't be blank" in errors_on(changeset).freshness

    assert {:error, {:unknown_event_version, "capacity.snapshot_observed", 3}} =
             EventRegistry.validate_payload("capacity.snapshot_observed", 3, payload)

    assert {:error, {:unknown_event_version, "capacity.snapshot_observed", 3}} =
             EventRegistry.upcast("capacity.snapshot_observed", 3, payload)
  end

  test "v1 events can explicitly reference artifact metadata" do
    artifact_id = Ecto.UUID.generate()

    assert {:ok, %{"decision" => "continue", "artifact_id" => ^artifact_id}} =
             EventRegistry.validate_payload("decision.recorded", 1, %{
               "decision" => "continue",
               "artifact_id" => artifact_id
             })
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp legacy_capacity_payload do
    %{
      "snapshot_id" => "22222222-2222-4222-8222-222222222222",
      "contract_version" => 1,
      "capacity_state" => "known",
      "windows" => %{
        "items" => [%{"kind" => "five_hour", "state" => "known", "used_percent" => 25.0}]
      },
      "observed_at" => "2026-08-30T12:00:00Z",
      "expires_at" => "2026-08-30T12:05:00Z",
      "source" => %{"adapter_id" => "legacy.adapter", "method" => "probe"},
      "scope" => "account",
      "confidence" => "high",
      "support_tier" => "supported",
      "compatibility_state" => "compatible",
      "extensions" => %{}
    }
  end
end
