defmodule Shoestring.Cobbler.PlanIndependenceTest do
  use ExUnit.Case, async: true
  alias Shoestring.Cobbler.PlanIndependence
  defp task(id, files), do: %{"id" => id, "hints" => %{"files" => files}}

  defp metadata(extra \\ %{}),
    do: Map.merge(%{verified?: true, files: ["lib/a.ex", "lib/b.ex"], symlinks: []}, extra)

  test "disjoint declared scopes are eligible evidence in deterministic order" do
    tasks = [task("b", ["lib/b.ex"]), task("a", ["lib/a.ex"])]
    decision = PlanIndependence.declared(tasks, metadata())
    assert decision["disposition"] == "eligible"
    assert decision["task_ids"] == ["a", "b"]
    assert decision == PlanIndependence.declared(Enum.reverse(tasks), metadata())
    assert decision["blocker_count"] == 0
  end

  test "unknown scopes and unverified metadata default sequential" do
    assert PlanIndependence.declared([task("a", []), task("b", ["lib/b.ex"])], metadata())[
             "disposition"
           ] == "sequential"

    assert PlanIndependence.declared([task("a", ["lib/a.ex"])], %{})["disposition"] ==
             "sequential"

    assert PlanIndependence.declared([], metadata())["disposition"] == "sequential"
  end

  test "same files, directory descendants and case variants overlap conservatively" do
    for {left, right} <- [
          {"lib/a.ex", "lib/a.ex"},
          {"lib/", "lib/a.ex"},
          {"lib/A.ex", "lib/a.ex"}
        ] do
      result = PlanIndependence.declared([task("a", [left]), task("b", [right])], metadata())
      assert result["disposition"] == "sequential"
      assert Enum.any?(result["blockers"], &(&1["reason"] == "scope_overlap"))
    end

    refute PlanIndependence.overlap?("lib/a", "lib/ab.ex")
  end

  test "shared migrations, lockfiles, central configuration and registry surfaces stay sequential" do
    for path <- [
          "priv/repo/migrations/one.exs",
          "config/runtime.exs",
          "mix.lock",
          "Cargo.lock",
          "pyproject.toml",
          "lib/app/event_registry.ex",
          ".github/workflows/test.yml"
        ] do
      result = PlanIndependence.declared([task("a", [path]), task("b", ["lib/b.ex"])], metadata())
      assert result["disposition"] == "sequential", path
      assert Enum.any?(result["blockers"], &(&1["reason"] == "shared_surface"))
    end

    result =
      PlanIndependence.declared(
        [task("a", ["lib/app"]), task("b", ["other.ex"])],
        metadata(%{files: ["lib/app/application.ex"]})
      )

    assert result["disposition"] == "sequential"
  end

  test "symlink scopes and descendants cannot supply independence evidence" do
    result =
      PlanIndependence.declared(
        [task("a", ["lib/link/file.ex"])],
        metadata(%{symlinks: ["lib/link"]})
      )

    assert result["disposition"] == "sequential"
    assert hd(result["blockers"])["reason"] == "symlink_scope"
  end

  test "unsafe paths, duplicate task IDs and oversized sets fail closed" do
    for path <- [
          "../escape",
          "/absolute",
          "lib/../escape",
          "lib//a",
          "lib/./a",
          "lib\\a",
          "bad\nname"
        ] do
      assert PlanIndependence.declared([task("a", [path])], metadata())["disposition"] ==
               "sequential"
    end

    assert PlanIndependence.declared([task("a", ["one"]), task("a", ["two"])], metadata())[
             "disposition"
           ] == "sequential"

    assert PlanIndependence.declared(Enum.map(1..65, &task(to_string(&1), ["one"])), metadata())[
             "disposition"
           ] == "sequential"

    assert PlanIndependence.actual(%{"a" => List.duplicate("one", 4097)}, metadata())[
             "disposition"
           ] == "sequential"
  end

  test "actual overlap overrides earlier disjoint declarations" do
    assert PlanIndependence.declared(
             [task("a", ["lib/a.ex"]), task("b", ["lib/b.ex"])],
             metadata()
           )["disposition"] == "eligible"

    result =
      PlanIndependence.actual(%{"a" => ["lib/a.ex"], "b" => ["lib/a.ex", "lib/b.ex"]}, metadata())

    assert result["disposition"] == "sequential"
    assert result["source"] == "actual"
    assert hd(result["blockers"])["task_ids"] == ["a", "b"]
  end

  test "actual empty changes are allowed while unknown evidence remains blocked" do
    assert PlanIndependence.actual(%{"a" => [], "b" => ["lib/b.ex"]}, metadata())["disposition"] ==
             "eligible"

    assert PlanIndependence.actual(%{"a" => []}, %{})["disposition"] == "sequential"
  end

  test "declared shared symbols block otherwise disjoint file hints" do
    tasks =
      for {id, path} <- [{"a", "lib/a.ex"}, {"b", "lib/b.ex"}],
          do: put_in(task(id, [path]), ["hints", "symbols"], ["Shared.Registry"])

    result = PlanIndependence.declared(tasks, metadata())
    assert result["disposition"] == "sequential"
    assert Enum.any?(result["blockers"], &(&1["reason"] == "symbol_overlap"))
  end
end
