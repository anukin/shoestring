defmodule Shoestring.Cobbler.PlanContractDecisionTest do
  @moduledoc """
  Pure tests for a task's optional `decision` (iteration 19): bounded,
  explicit, unique within the plan, its file listed in the task's expected
  artifacts, and absent from every task that does not declare one, so
  existing plans keep their digest.
  """
  use ExUnit.Case, async: true

  alias Shoestring.Cobbler.PlanContract
  alias Shoestring.Test.PlanFixtures

  defp decision(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "cover",
        "question" => "Which cover?",
        "min_options" => 2,
        "max_options" => 4,
        "allow_reject" => true
      },
      overrides
    )
  end

  defp deciding_task(id, decision) do
    PlanFixtures.task(id, "Draw covers", [], %{
      "expected_artifacts" => [PlanContract.decision_file(decision["id"])],
      "decision" => decision
    })
  end

  defp plan(tasks), do: PlanFixtures.plan(%{"tasks" => tasks})

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _} -> message end)
    |> inspect()
  end

  test "a declared decision is normalized and carried in the canonical rendering" do
    assert {:ok, contract} = PlanContract.new(plan([deciding_task("covers", decision())]))
    assert [%{"decision" => decision}] = contract.content["tasks"]
    assert decision == decision()

    assert {:ok, replayed} =
             PlanContract.from_canonical_json(PlanContract.canonical_json(contract))

    assert replayed.digest == contract.digest
  end

  test "a task without a decision has no decision key, so its digest does not move" do
    assert {:ok, contract} = PlanContract.new(PlanFixtures.plan())
    refute Enum.any?(contract.content["tasks"], &Map.has_key?(&1, "decision"))
    refute PlanContract.canonical_json(contract) =~ "decision"
  end

  test "the decision file must be listed in the task's expected artifacts" do
    task = PlanFixtures.task("covers", "Draw covers", [], %{"decision" => decision()})
    assert {:error, {:invalid_plan, changeset}} = PlanContract.new(plan([task]))
    assert errors(changeset) =~ ".shoestring/decisions/cover/decision.json"
  end

  test "every field is required and bounded; nothing is defaulted" do
    for {field, value, message} <- [
          {"allow_reject", nil, "can't be blank"},
          {"allow_reject", "yes", "true or false"},
          {"min_options", 0, "between"},
          {"max_options", 13, "between"},
          {"max_options", 1, "between 2 and"},
          {"question", String.duplicate("q", 2_001), "is too long"},
          {"id", "Not A Slug", "lowercase slug"}
        ] do
      bad = Map.put(decision(), field, value)
      bad = if value == nil, do: Map.delete(bad, field), else: bad

      task =
        PlanFixtures.task("covers", "Draw covers", [], %{
          "expected_artifacts" => [PlanContract.decision_file(bad["id"] || "x")],
          "decision" => bad
        })

      assert {:error, {:invalid_plan, changeset}} = PlanContract.new(plan([task])),
             "#{field}=#{inspect(value)} was accepted"

      assert errors(changeset) =~ message, "#{field}: #{errors(changeset)}"
    end
  end

  test "an unknown decision field is refused" do
    task = deciding_task("covers", Map.put(decision(), "deadline", "tomorrow"))
    assert {:error, {:invalid_plan, changeset}} = PlanContract.new(plan([task]))
    assert errors(changeset) =~ "unsupported fields: deadline"
  end

  test "decision ids are unique within the plan" do
    tasks = [deciding_task("covers", decision()), deciding_task("posters", decision())]
    assert {:error, {:invalid_plan, changeset}} = PlanContract.new(plan(tasks))
    assert errors(changeset) =~ "unique"
  end
end
