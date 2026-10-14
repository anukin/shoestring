defmodule Shoestring.Cobbler.PlanScopeRecordingRegressionTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.Cobbler.PlanScopeCheck
  alias Shoestring.Test.PlanFanoutHelpers
  alias Shoestring.Trajectory.TrajectoryEvent

  test "overlap refusal is durably recordable with its complete structured blocker" do
    c =
      PlanFanoutHelpers.fixture(
        transform_tasks: fn [north, south, join] ->
          [north, Map.put(south, "hints", north["hints"]), join]
        end
      )

    assert {:ok, result} = PlanScopeCheck.record(c.goal.id, c.opts)
    assert result.evidence["decision"]["disposition"] == "sequential"

    assert [%{"task_ids" => ["north", "south"], "paths" => ["lib/north.ex", "lib/north.ex"]}] =
             result.evidence["decision"]["blockers"]

    stored = Repo.get!(TrajectoryEvent, result.event_id)
    assert stored.schema_version == 2
    assert Jason.decode!(stored.payload["decision_json"]) == result.evidence["decision"]
  end

  test "large overlap decisions retain the full count and explicit evidence bound" do
    paths = for depth <- 1..32, do: "lib/" <> Enum.join(List.duplicate("a", depth), "/")
    hints = %{"files" => paths, "symbols" => []}

    c =
      PlanFanoutHelpers.fixture(
        transform_tasks: fn [north, south, join] ->
          [Map.put(north, "hints", hints), Map.put(south, "hints", hints), join]
        end
      )

    assert {:ok, result} = PlanScopeCheck.record(c.goal.id, c.opts)
    decision = result.evidence["decision"]
    assert decision["blocker_count"] == 1024
    refute decision["evidence_complete"]
    assert length(decision["blockers"]) == 128

    assert Jason.decode!(Repo.get!(TrajectoryEvent, result.event_id).payload["decision_json"]) ==
             decision
  end
end
