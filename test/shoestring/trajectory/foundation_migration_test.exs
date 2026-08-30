defmodule Shoestring.Trajectory.FoundationMigrationTest do
  use Shoestring.DataCase, async: false

  test "the empty database migration creates the complete foundation" do
    assert foundation_tables() ==
             [
               "artifacts",
               "goals",
               "projector_positions",
               "tasks",
               "trajectory_events"
             ]
  end

  test "sqlite concurrency settings are explicit and enabled" do
    assert Application.fetch_env!(:shoestring, Shoestring.Repo)[:journal_mode] == :wal
    assert Application.fetch_env!(:shoestring, Shoestring.Repo)[:busy_timeout] == 2_000
    assert {:ok, %{rows: [["wal"]]}} = Repo.query("PRAGMA journal_mode")
    assert {:ok, %{rows: [[2_000]]}} = Repo.query("PRAGMA busy_timeout")
  end

  test "foundation tables use foreign keys and the canonical event indexes" do
    assert {:ok, %{rows: [[1]]}} = Repo.query("PRAGMA foreign_keys")

    assert index_names("trajectory_events") == [
             "trajectory_events_goal_id_idempotency_key_index",
             "trajectory_events_goal_id_sequence_index",
             "trajectory_events_parent_event_id_index",
             "trajectory_events_task_id_sequence_index"
           ]
  end

  test "projector positions persist status and visible failure detail" do
    assert {:ok, %{rows: rows}} = Repo.query("PRAGMA table_info(projector_positions)")
    assert Enum.map(rows, &Enum.at(&1, 1)) |> Enum.take(-2) == ["status", "error_detail"]
  end

  defp foundation_tables do
    {:ok, %{rows: rows}} =
      Repo.query(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'schema_%' ORDER BY name"
      )

    Enum.map(rows, &hd/1)
  end

  defp index_names(table) do
    {:ok, %{rows: rows}} = Repo.query("PRAGMA index_list(#{table})")

    rows
    |> Enum.map(&Enum.at(&1, 1))
    |> Enum.reject(&String.starts_with?(&1, "sqlite_autoindex_"))
    |> Enum.sort()
  end
end
