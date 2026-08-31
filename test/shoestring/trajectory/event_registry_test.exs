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
             {"harness.event_recorded", 1}
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
end
