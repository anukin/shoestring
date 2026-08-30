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

  test "the registry exposes exactly the initial v1 event types" do
    assert EventRegistry.registered_types() == [
             {"decision.recorded", 1},
             {"goal.created", 1},
             {"task.completed", 1},
             {"task.created", 1}
           ]
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

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
