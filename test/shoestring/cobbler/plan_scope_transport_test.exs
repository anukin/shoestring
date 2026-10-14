defmodule Shoestring.Cobbler.PlanScopeTransportTest do
  use ExUnit.Case, async: true
  alias Shoestring.Cobbler.PlanIndependence
  alias Shoestring.Trajectory.EventRegistry

  defp decision do
    PlanIndependence.declared(
      [
        %{"id" => "north", "hints" => %{"files" => ["lib/shared.ex"]}},
        %{"id" => "south", "hints" => %{"files" => ["lib/shared.ex"]}}
      ],
      %{verified?: true, files: [], symlinks: []}
    )
  end

  test "JSON transport preserves required nested evidence while rejecting hidden and malformed fields" do
    original = decision()
    assert {:ok, payload} = PlanIndependence.event_payload(%{"decision" => original})
    assert {:ok, ^original} = PlanIndependence.decode_event_decision(payload["decision_json"])
    assert hd(original["blockers"])["paths"] == ["lib/shared.ex", "lib/shared.ex"]

    for incoming <- [
          Map.put(original, "raw_transcript", "private fixture content"),
          Map.update!(
            original,
            "blockers",
            &[Map.put(hd(&1), "thinking", "hidden fixture content")]
          ),
          Map.put(original, "observed_changes", %{"north" => ["../outside.ex"]})
        ] do
      assert {:error, :invalid_scope_evidence} =
               PlanIndependence.decode_event_decision(Jason.encode!(incoming))
    end

    assert {:error, :invalid_scope_evidence} = PlanIndependence.decode_event_decision("{invalid}")

    assert {:error, :scope_evidence_oversized} =
             PlanIndependence.decode_event_decision(String.duplicate("x", 65_537))
  end

  test "the registry accepts version 2 and retained version 1 events and rejects invalid JSON contracts" do
    payload = %{
      "execution_id" => Ecto.UUID.generate(),
      "revision_number" => 1,
      "plan_digest" => String.duplicate("a", 64),
      "accepted_base" => String.duplicate("b", 40),
      "repository_observation" => "verified_accepted_base"
    }

    valid =
      PlanIndependence.declared(
        [%{"id" => "north", "hints" => %{"files" => ["lib/north.ex"]}}],
        %{verified?: true, files: [], symlinks: []}
      )

    assert {:ok, _} =
             EventRegistry.validate_payload(
               "cobbler.plan.independence.evaluated",
               1,
               Map.put(payload, "decision", valid)
             )

    assert {:ok, stored} =
             PlanIndependence.event_payload(Map.put(payload, "decision", decision()))

    assert {:ok, _} =
             EventRegistry.validate_payload("cobbler.plan.independence.evaluated", 2, stored)

    assert {:error, _} =
             EventRegistry.validate_payload(
               "cobbler.plan.independence.evaluated",
               2,
               Map.put(stored, "decision_json", "{}")
             )
  end
end
