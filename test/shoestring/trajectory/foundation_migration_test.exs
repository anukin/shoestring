defmodule Shoestring.Trajectory.FoundationMigrationTest do
  use Shoestring.DataCase, async: false

  test "the empty database migration creates the complete foundation" do
    expected_tables = [
      "artifacts",
      "goals",
      "harness_capacity_snapshots",
      "harness_capacity_windows",
      "harness_checkpoint_artifact_references",
      "harness_checkpoints",
      "harness_dispatches",
      "harness_execution_leases",
      "harness_runs",
      "oban_jobs",
      "projector_positions",
      "sqlite_sequence",
      "tasks",
      "trajectory_events"
    ]

    assert expected_tables -- foundation_tables() == []
  end

  test "sqlite concurrency settings are explicit and enabled" do
    assert Application.fetch_env!(:shoestring, Shoestring.Repo)[:journal_mode] == :wal
    assert Application.fetch_env!(:shoestring, Shoestring.Repo)[:busy_timeout] == 2_000
    assert {:ok, %{rows: [["wal"]]}} = Repo.query("PRAGMA journal_mode")
    assert {:ok, %{rows: [[2_000]]}} = Repo.query("PRAGMA busy_timeout")
  end

  test "foundation tables use foreign keys and the canonical event indexes" do
    assert {:ok, %{rows: [[1]]}} = Repo.query("PRAGMA foreign_keys")

    expected_indexes = [
      "trajectory_events_goal_id_idempotency_key_index",
      "trajectory_events_goal_id_run_id_sequence_index",
      "trajectory_events_goal_id_sequence_index",
      "trajectory_events_parent_event_id_index",
      "trajectory_events_task_id_sequence_index"
    ]

    assert expected_indexes -- index_names("trajectory_events") == []
  end

  test "projector positions persist status and visible failure detail" do
    assert {:ok, %{rows: rows}} = Repo.query("PRAGMA table_info(projector_positions)")
    assert Enum.map(rows, &Enum.at(&1, 1)) |> Enum.take(-2) == ["status", "error_detail"]
  end

  test "harness tables carry normalized constraints and query indexes" do
    assert column_names("harness_runs") |> Enum.member?("dispatch_id")
    assert column_names("harness_execution_leases") |> Enum.member?("deadline")
    assert column_names("harness_checkpoints") |> Enum.member?("stop_reason")
    assert column_names("harness_capacity_snapshots") |> Enum.member?("capacity_state")
    assert column_names("harness_capacity_windows") |> Enum.member?("used_percent")
    assert column_names("harness_dispatches") |> Enum.member?("job_id")
    assert column_names("harness_dispatches") |> Enum.member?("outcome_code")
    assert column_names("harness_dispatches") |> Enum.member?("outcome_at")
    assert column_names("harness_runs") |> Enum.member?("extensions")
    assert column_names("oban_jobs") |> Enum.member?("args")

    expected_run_indexes = [
      "harness_runs_dispatch_id_index",
      "harness_runs_goal_id_status_index",
      "harness_runs_goal_id_task_id_index"
    ]

    assert expected_run_indexes -- index_names("harness_runs") == []

    expected_window_indexes = [
      "harness_capacity_windows_reset_at_index",
      "harness_capacity_windows_snapshot_id_kind_index"
    ]

    assert expected_window_indexes -- index_names("harness_capacity_windows") == []

    expected_dispatch_indexes = [
      "harness_dispatches_goal_id_status_index",
      "harness_dispatches_job_id_index",
      "harness_dispatches_run_id_status_index"
    ]

    assert expected_dispatch_indexes -- index_names("harness_dispatches") == []

    assert ["oban_jobs_state_queue_priority_scheduled_at_id_index"] -- index_names("oban_jobs") ==
             []
  end

  test "sqlite enforces harness status and capacity window constraints directly" do
    goal_id = "00000000-0000-4000-8000-000000000401"
    task_id = "00000000-0000-4000-8000-000000000402"
    run_id = "00000000-0000-4000-8000-000000000403"
    snapshot_id = "00000000-0000-4000-8000-000000000404"
    window_id = "00000000-0000-4000-8000-000000000405"
    now = "2026-08-30T12:00:00.000000Z"

    assert {:ok, _} =
             Repo.query(
               "INSERT INTO goals (id, owner_id, title, status, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
               [goal_id, "00000000-0000-4000-8000-000000000406", "Goal", "active", now, now]
             )

    assert {:ok, _} =
             Repo.query(
               "INSERT INTO tasks (id, goal_id, title, status, position, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
               [task_id, goal_id, "Task", "pending", 0, now, now]
             )

    assert {:ok, _} =
             Repo.query(
               "INSERT INTO harness_runs (id, goal_id, task_id, dispatch_id, provider_id, workspace_ref, request_version, prompt, policy, requested_capabilities, status, projection_sequence, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
               [
                 run_id,
                 goal_id,
                 task_id,
                 "00000000-0000-4000-8000-000000000407",
                 "test",
                 "workspace",
                 1,
                 "prompt",
                 "{}",
                 "{}",
                 "requested",
                 0,
                 now,
                 now
               ]
             )

    assert {:error, _} =
             Repo.query("UPDATE harness_runs SET status = 'unsafe' WHERE id = ?", [run_id])

    assert {:ok, _} =
             Repo.query(
               "INSERT INTO harness_capacity_snapshots (id, goal_id, run_id, contract_version, capacity_state, observed_at, source_adapter_id, source_method, scope, confidence, support_tier, compatibility_state, extensions, projection_sequence, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
               [
                 snapshot_id,
                 goal_id,
                 run_id,
                 1,
                 "known",
                 now,
                 "test",
                 "probe",
                 "account",
                 "high",
                 "supported",
                 "compatible",
                 "{}",
                 1,
                 now,
                 now
               ]
             )

    assert {:error, _} =
             Repo.query(
               "INSERT INTO harness_capacity_windows (id, snapshot_id, kind, state, used_percent, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
               [window_id, snapshot_id, "five_hour", "known", 101, now, now]
             )

    dispatch_id = "00000000-0000-4000-8000-000000000408"

    assert {:ok, _} =
             Repo.query(
               "INSERT INTO harness_dispatches (dispatch_id, goal_id, task_id, run_id, request_version, status, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
               [dispatch_id, goal_id, task_id, run_id, 1, "requested", now, now]
             )

    assert {:ok, _} =
             Repo.query(
               "UPDATE harness_dispatches SET status = 'effect_unknown', outcome_code = 'effect_unknown', outcome_at = ? WHERE dispatch_id = ?",
               [now, dispatch_id]
             )

    assert {:error, _} =
             Repo.query(
               "UPDATE harness_dispatches SET status = 'unsafe' WHERE dispatch_id = ?",
               [dispatch_id]
             )

    assert {:error, _} =
             Repo.query(
               "INSERT INTO harness_dispatches (dispatch_id, goal_id, task_id, run_id, request_version, status, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
               [dispatch_id, goal_id, task_id, run_id, 1, "requested", now, now]
             )
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

  defp column_names(table) do
    {:ok, %{rows: rows}} = Repo.query("PRAGMA table_info(#{table})")
    Enum.map(rows, &Enum.at(&1, 1))
  end
end
