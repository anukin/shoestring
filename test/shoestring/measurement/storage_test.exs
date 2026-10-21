defmodule Shoestring.Measurement.StorageTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.{Measurement, Repo}
  alias Shoestring.Measurement.Dataset
  alias Shoestring.Test.{ElvesHelpers, MeasurementFixtures, ProviderCliGuard}
  alias Shoestring.Trajectory.TrajectoryEvent
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = System.get_env("SHOESTRING_TEST_STATE_DIR")
    System.put_env("SHOESTRING_TEST_STATE_DIR", dir)

    on_exit(fn ->
      if previous,
        do: System.put_env("SHOESTRING_TEST_STATE_DIR", previous),
        else: System.delete_env("SHOESTRING_TEST_STATE_DIR")
    end)

    guard = ProviderCliGuard.install!()
    %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()
    fixture = MeasurementFixtures.history(goal_id: goal.id, task_id: task.id)
    for event <- fixture.events, do: Repo.insert!(event)
    %{fixture: fixture, guard: guard}
  end

  test "rebuild replaces only derived data and reproduces the same private bytes", %{guard: guard} do
    before = Repo.all(from e in TrajectoryEvent, order_by: [e.goal_id, e.sequence])
    assert {:ok, first} = Measurement.rebuild()
    bytes = File.read!(Measurement.cache_path())
    assert {:ok, second} = Measurement.rebuild()
    assert first == second
    assert bytes == File.read!(Measurement.cache_path())
    assert {:ok, dataset} = Measurement.snapshot()
    assert bytes == Dataset.encode(dataset)
    assert Bitwise.band(File.stat!(Measurement.cache_path()).mode, 0o777) == 0o600
    assert Repo.all(from e in TrajectoryEvent, order_by: [e.goal_id, e.sequence]) == before
    ProviderCliGuard.assert_no_provider_cli_spawned!(guard)
  end

  test "export refuses overwrite and deleting the cache preserves history and exports", %{
    tmp_dir: dir,
    guard: guard
  } do
    path = Path.join(dir, "export.json")
    assert {:ok, _} = Measurement.rebuild()
    assert {:ok, summary} = Measurement.export(path)
    assert summary["quality"]["run_count"] == 1
    bytes = File.read!(path)
    count = Repo.aggregate(TrajectoryEvent, :count)
    assert {:error, :export_already_exists} = Measurement.export(path)
    assert File.read!(path) == bytes
    assert {:error, :confirmation_required} = Measurement.delete_cache(confirm: false)
    assert File.exists?(Measurement.cache_path())
    assert :ok = Measurement.delete_cache(confirm: true)
    refute File.exists?(Measurement.cache_path())
    assert File.read!(path) == bytes
    assert Repo.aggregate(TrajectoryEvent, :count) == count
    assert :ok = Measurement.delete_cache(confirm: true)
    ProviderCliGuard.assert_no_provider_cli_spawned!(guard)
  end

  test "report contains aggregate quality without prompts, IDs or paths", %{guard: guard} do
    assert {:ok, report} = Measurement.report()
    assert report["quality"]["run_count"] == 1
    assert report["quality"]["missingness"]["model"] == 1
    assert report["quality"]["assignable_consumption_rows"] == 0
    refute report["quality"]["forecast_training_ready"]
    bytes = Jason.encode!(report)
    refute bytes =~ "Synthetic task text"
    refute bytes =~ "workspace/fixture"
    refute bytes =~ "run_id"
    refute File.exists?(Measurement.cache_path())
    ProviderCliGuard.assert_no_provider_cli_spawned!(guard)
  end

  test "CLI rejects unconfirmed deletion, unrelated flags, duplicate flags and invalid splits" do
    for args <- [
          ["delete"],
          ["delete", "--no-confirm"],
          ["report", "--confirm"],
          ["report", "--split-at", "tomorrow"],
          ["export"],
          ["rebuild", "--split-at", "2026-10-01T00:00:00Z", "--split-at", "2026-10-02T00:00:00Z"]
        ] do
      assert_raise Mix.Error, ~r/Invalid arguments/, fn ->
        Mix.Tasks.Shoestring.Measurements.run(args)
      end
    end
  end
end
