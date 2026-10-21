defmodule Shoestring.Diagnostics.StorageTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.{Diagnostics, Repo}
  alias Shoestring.Diagnostics.Bundle
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

  test "preview has no file side effects, leaves history unchanged, and never starts providers",
       %{tmp_dir: dir, guard: guard} do
    before = Repo.all(from e in TrajectoryEvent, order_by: [e.goal_id, e.sequence])
    files = File.ls!(dir)
    assert {:ok, first} = Diagnostics.preview()
    assert {:ok, second} = Diagnostics.preview()
    assert first == second
    assert first["manifest"]["selected_events"] == 6
    assert first["bundle"]["health"]["repository"] == "readable"
    assert first["bundle"]["health"]["sqlite_version"] =~ ~r/^\d+\.\d+\.\d+$/
    assert first["bundle"]["health"]["provider_authentication"] == "not_checked"
    assert File.ls!(dir) == files
    assert Repo.all(from e in TrajectoryEvent, order_by: [e.goal_id, e.sequence]) == before
    ProviderCliGuard.assert_no_provider_cli_spawned!(guard)
  end

  test "only a matching preview confirmation can create an exclusive private export", %{
    tmp_dir: dir,
    guard: guard
  } do
    path = Path.join(dir, "diagnostics.json")
    assert {:error, :diagnostic_confirmation_mismatch} = Diagnostics.export(path, nil)

    assert {:error, :diagnostic_confirmation_mismatch} =
             Diagnostics.export(path, String.duplicate("0", 64))

    refute File.exists?(path)
    assert {:ok, preview} = Diagnostics.preview()
    assert {:ok, manifest} = Diagnostics.export(path, preview["confirmation_sha256"])
    bytes = File.read!(path)
    assert bytes == Bundle.encode(preview["bundle"])
    assert manifest["confirmation_sha256"] == Bundle.digest(bytes)
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600

    assert {:error, :diagnostic_export_exists} =
             Diagnostics.export(path, preview["confirmation_sha256"])

    assert File.read!(path) == bytes
    assert Repo.aggregate(TrajectoryEvent, :count) == 6
    ProviderCliGuard.assert_no_provider_cli_spawned!(guard)
  end

  test "changed selected history or configuration requires a fresh preview", %{
    fixture: fixture,
    tmp_dir: dir
  } do
    path = Path.join(dir, "changed.json")
    assert {:ok, preview} = Diagnostics.preview()

    event =
      MeasurementFixtures.event(
        fixture.goal_id,
        fixture.task_id,
        fixture.run_id,
        7,
        "run.failed",
        20,
        %{"run_id" => fixture.run_id}
      )

    Repo.insert!(event)

    assert {:error, :diagnostic_confirmation_mismatch} =
             Diagnostics.export(path, preview["confirmation_sha256"])

    refute File.exists?(path)
    assert {:ok, updated} = Diagnostics.preview()
    previous = Application.get_env(:shoestring, :api_execution)

    Application.put_env(:shoestring, :api_execution, %{
      enabled: true,
      monthly_cap_microusd: 1_000_000
    })

    on_exit(fn ->
      if previous,
        do: Application.put_env(:shoestring, :api_execution, previous),
        else: Application.delete_env(:shoestring, :api_execution)
    end)

    assert {:error, :diagnostic_confirmation_mismatch} =
             Diagnostics.export(path, updated["confirmation_sha256"])

    refute File.exists?(path)
  end

  test "selection is explicitly bounded, goal-scoped and refuses invalid arguments", %{
    fixture: fixture
  } do
    assert {:ok, preview} = Diagnostics.preview(limit: 2, goal: fixture.goal_id)
    assert preview["manifest"]["selected_events"] == 2
    assert preview["manifest"]["omitted_events"] == 4
    assert Enum.map(preview["bundle"]["events"], & &1["sequence"]) == [5, 6]
    assert {:ok, empty} = Diagnostics.preview(goal: Ecto.UUID.generate())
    assert empty["manifest"]["selected_events"] == 0

    for opts <- [
          [limit: 0],
          [limit: 201],
          [limit: "2"],
          [goal: "bad-identifier"],
          [limit: 2, limit: 3],
          [confirm: true]
        ] do
      assert {:error, :invalid_diagnostic_selection} = Diagnostics.preview(opts)
    end
  end

  test "CLI refuses export without confirmation and ambiguous or unknown arguments" do
    for args <- [
          ["export", "unused.json"],
          ["preview", "--confirm", "anything"],
          ["preview", "--limit", "nope"],
          ["preview", "--limit", "2", "--limit", "3"],
          ["preview", "--upload"],
          ["export"]
        ] do
      assert_raise Mix.Error, ~r/Invalid arguments/, fn ->
        Mix.Tasks.Shoestring.Diagnostics.run(args)
      end
    end
  end

  test "symlink export refuses overwrite of its target", %{tmp_dir: dir} do
    target = Path.join(dir, "keep.json")
    path = Path.join(dir, "link.json")
    File.write!(target, "existing-private-data")
    File.ln_s!(target, path)
    assert {:ok, preview} = Diagnostics.preview()

    assert {:error, :diagnostic_export_exists} =
             Diagnostics.export(path, preview["confirmation_sha256"])

    assert File.read!(target) == "existing-private-data"
  end

  test "oversized selected source is refused before export", %{fixture: fixture, tmp_dir: dir} do
    event =
      MeasurementFixtures.event(
        fixture.goal_id,
        fixture.task_id,
        fixture.run_id,
        7,
        "run.requested",
        20,
        %{"prompt" => String.duplicate("x", Bundle.max_source_bytes() + 1)}
      )

    Repo.insert!(event)
    assert {:error, :diagnostic_source_limit} = Diagnostics.preview(limit: 1)
    path = Path.join(dir, "oversized.json")

    assert {:error, :diagnostic_source_limit} =
             Diagnostics.export(path, String.duplicate("0", 64), limit: 1)

    refute File.exists?(path)
  end

  test "inspection of missing state does not create a database or call the inspector", %{
    tmp_dir: dir
  } do
    refute File.exists?(Shoestring.State.database_path())

    assert {:error, :existing_database_required} =
             Shoestring.CLI.Repository.with_existing_repo(fn _ ->
               flunk("unexpected inspector")
             end)

    assert File.ls!(dir) == []
  end
end
