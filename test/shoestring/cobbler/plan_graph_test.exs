defmodule Shoestring.Cobbler.PlanGraphTest do
  @moduledoc """
  Pure tests for dependency-graph validation and deterministic ordering.
  No database, no processes, no execution.
  """
  use ExUnit.Case, async: true

  alias Shoestring.Cobbler.PlanGraph

  defp task(id, deps \\ []), do: %{"id" => id, "depends_on" => deps}

  describe "deterministic ordering" do
    test "orders a diamond so every dependency precedes its dependents" do
      tasks = [task("a"), task("b", ["a"]), task("c", ["a"]), task("d", ["b", "c"])]

      assert {:ok, ["a", "b", "c", "d"]} = PlanGraph.validate(tasks)
    end

    test "breaks ties by declared order, not by id" do
      # "zed" is declared first and "alpha" second; both are ready at once.
      tasks = [task("zed"), task("alpha"), task("omega", ["zed", "alpha"])]

      assert {:ok, ["zed", "alpha", "omega"]} = PlanGraph.validate(tasks)
    end

    test "the same graph written in a different task order yields a different but stable order" do
      forward = [task("a"), task("b"), task("c", ["a", "b"])]
      reversed = [task("b"), task("a"), task("c", ["a", "b"])]

      assert {:ok, ["a", "b", "c"]} = PlanGraph.validate(forward)
      assert {:ok, ["b", "a", "c"]} = PlanGraph.validate(reversed)

      # Repeating either call reproduces its own order exactly.
      assert PlanGraph.validate(forward) == PlanGraph.validate(forward)
      assert PlanGraph.validate(reversed) == PlanGraph.validate(reversed)
    end

    test "a task with no edges at all is still ordered" do
      assert {:ok, ["only"]} = PlanGraph.validate([task("only")])
    end
  end

  describe "structured validation failures" do
    test "rejects duplicate task ids" do
      tasks = [task("a"), task("a"), task("b", ["a"])]

      assert {:error, {:duplicate_task_ids, ["a"]}} = PlanGraph.validate(tasks)
    end

    test "rejects a self dependency" do
      tasks = [task("a"), task("b", ["b"])]

      assert {:error, {:self_dependency, ["b"]}} = PlanGraph.validate(tasks)
    end

    test "rejects a dependency on an id no task declares" do
      tasks = [task("a"), task("b", ["ghost"])]

      assert {:error, {:unknown_dependency, [%{task: "b", depends_on: "ghost"}]}} =
               PlanGraph.validate(tasks)
    end

    test "rejects the same dependency listed twice" do
      tasks = [task("a"), task("b", ["a", "a"])]

      assert {:error, {:duplicate_dependency, [%{task: "b", depends_on: "a"}]}} =
               PlanGraph.validate(tasks)
    end

    test "rejects a two-node cycle and names both members" do
      tasks = [task("a", ["b"]), task("b", ["a"])]

      assert {:error, {:cycle, cycle}} = PlanGraph.validate(tasks)
      assert Enum.sort(cycle) == ["a", "b"]
    end

    test "rejects a longer cycle and returns a witness that is actually a cycle" do
      tasks = [task("a", ["c"]), task("b", ["a"]), task("c", ["b"])]

      assert {:error, {:cycle, cycle}} = PlanGraph.validate(tasks)
      assert Enum.sort(cycle) == ["a", "b", "c"]

      # Every consecutive pair in the witness is a real edge, and it closes.
      edges = Map.new(tasks, &{&1["id"], &1["depends_on"]})
      closed = cycle ++ [hd(cycle)]

      for [from, to] <- Enum.chunk_every(closed, 2, 1, :discard) do
        assert to in Map.fetch!(edges, from),
               "#{from} -> #{to} is not an edge in the fixture graph"
      end
    end

    test "a node that merely depends on a cycle is not reported as the cycle" do
      tasks = [task("a", ["b"]), task("b", ["a"]), task("downstream", ["a"])]

      assert {:error, {:cycle, cycle}} = PlanGraph.validate(tasks)
      refute "downstream" in cycle
    end

    test "the cycle witness is stable across repeated calls" do
      tasks = [task("a", ["c"]), task("b", ["a"]), task("c", ["b"])]

      assert PlanGraph.validate(tasks) == PlanGraph.validate(tasks)
    end
  end
end
