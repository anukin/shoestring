defmodule Shoestring.Cobbler.PlanContractTest do
  use ExUnit.Case, async: true
  alias Shoestring.Cobbler.PlanContract
  import Shoestring.Test.PlanHelpers

  @moduledoc "Feature tests for the new v1 contract; no pre-fix regression claim."

  test "explicit contracts and deterministic DAG ordering" do
    assert {:ok, contract} = PlanContract.goal(goal_contract())
    assert contract == goal_contract()
    assert {:ok, [a, b]} = PlanContract.validate_dag(plan())
    assert [a, b] == [task_a(), task_b()]

    assert {:ok, [^a, ^b]} =
             PlanContract.validate_dag(Map.update!(plan(), "tasks", &Enum.reverse/1))
  end

  test "digest ignores object key ordering and survives JSON round trips" do
    content = plan()

    assert PlanContract.digest(content) ==
             "13dda4995db14b073d6fbed3353a0b22fe44a6d672b79f5949dfff9ff776001e"

    decoded = content |> Jason.encode!() |> Jason.decode!()
    assert PlanContract.digest(content) == PlanContract.digest(decoded)

    refute PlanContract.digest(content) ==
             PlanContract.digest(
               put_in(content, ["tasks", Access.at(0), "outcome"], "Different outcome")
             )
  end

  test "missing explicit goal fields fail closed" do
    for key <- Map.keys(goal_contract()) do
      assert {:error, errors} = PlanContract.goal(Map.delete(goal_contract(), key))
      assert %{path: [key], code: :required} in errors
    end
  end

  test "missing task fields fail closed" do
    for key <- Map.keys(task(task_a())) do
      bad = put_in(plan(), ["tasks", Access.at(0)], Map.delete(task(task_a()), key))
      assert {:error, _} = PlanContract.validate_dag(bad)
    end
  end

  test "malformed and oversized terms fail as structured errors without exceptions" do
    for bad <- [
          nil,
          [],
          %{},
          %{version: 1},
          %{1 => 1},
          %{"tasks" => self()},
          %{"tasks" => [1 | :bad]},
          %{"tasks" => String.duplicate("x", 131_073)},
          %{"tasks" => <<255>>},
          Map.put(plan(), "tasks", List.duplicate(task(task_a()), 5000))
        ] do
      assert {:error, errors} = PlanContract.plan(bad)
      assert Enum.all?(errors, &match?(%{path: _, code: _}, &1))
    end

    deep = Enum.reduce(1..20, "x", fn _, acc -> %{"nested" => acc} end)
    assert {:error, _} = PlanContract.plan(deep)
  end

  test "unknown fields, unsupported versions and model provenance are rejected" do
    for bad <- [
          Map.put(plan(), "command", "mix precommit"),
          Map.put(plan(), "version", 2),
          put_in(plan(), ["provenance", "kind"], "model"),
          put_in(plan(), ["goal", "budget", "reserve_override"], true),
          put_in(plan(), ["tasks", Access.at(0), "checkpoint", "shell"], "true")
        ] do
      assert {:error, _} = PlanContract.validate_dag(bad)
    end
  end

  test "acceptance requires criteria, evidence and named trusted gates" do
    for bad <- [
          put_in(plan(), ["tasks", Access.at(0), "acceptance", "criteria"], []),
          put_in(plan(), ["goal", "acceptance", "gates"], ["echo success"]),
          put_in(plan(), ["tasks", Access.at(0), "acceptance", "gates"], ["model_success"]),
          put_in(plan(), ["goal", "acceptance", "evidence"], [])
        ] do
      assert {:error, _} = PlanContract.validate_dag(bad)
    end

    assert PlanContract.trusted_gates() == ["mix_precommit"]
  end

  test "duplicate IDs, duplicate edges, self edges, missing dependencies and cycles" do
    a = task_a()
    b = task_b()

    cases = [
      {[task(a), task(a)], :duplicate_ids},
      {[task(a), task(b, [a, a])], :duplicate_edges},
      {[task(a, [a])], :self_edge},
      {[task(a, [b])], :missing_reference},
      {[task(a, [b]), task(b, [a])], :cycle}
    ]

    for {tasks, code} <- cases do
      assert {:error, errors} = PlanContract.validate_dag(Map.put(plan(), "tasks", tasks))
      assert Enum.any?(errors, &(&1.code == code))
    end
  end

  test "bounds are finite positive integers and task totals include all attempts" do
    for value <- [0, -1, 1.5, "2", nil, 11] do
      assert {:error, _} =
               PlanContract.validate_dag(
                 put_in(plan(), ["tasks", Access.at(0), "execution", "max_attempts"], value)
               )
    end

    bad = put_in(plan(), ["tasks", Access.at(0), "execution", "max_tool_calls"], 11)
    assert {:error, [%{code: :exceeds_goal}]} = PlanContract.validate_bounds(goal_contract(), bad)
    bounded = put_in(goal_contract(), ["budget", "max_total_response_tokens"], 3999)
    assert {:error, [%{code: :exceeds_budget}]} = PlanContract.validate_bounds(bounded, plan())
  end

  test "empty outcomes, blank checkpoints and excess graph count fail" do
    for bad <- [
          put_in(plan(), ["tasks", Access.at(0), "outcome"], " "),
          put_in(plan(), ["tasks", Access.at(0), "checkpoint", "condition"], ""),
          Map.put(plan(), "tasks", []),
          Map.put(plan(), "tasks", List.duplicate(task(task_a()), 65))
        ] do
      assert {:error, _} = PlanContract.validate_dag(bad)
    end
  end
end
