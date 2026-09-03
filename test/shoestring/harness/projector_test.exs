defmodule Shoestring.Harness.ProjectorTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.Harness.{
    CapacitySnapshotRecord,
    CapacityWindowRecord,
    CheckpointRecord,
    ExecutionLeaseRecord,
    Identity,
    Projector,
    RunRecord,
    RunRequest,
    Runs
  }

  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{Goal, Task}

  @run_id "00000000-0000-4000-8000-000000000099"
  @snapshot_id "00000000-0000-4000-8000-000000000010"
  @grant_id "00000000-0000-4000-8000-000000000011"
  @checkpoint_id "00000000-0000-4000-8000-000000000012"

  test "canonical harness events project and rebuild runs, leases, checkpoints, and capacity", %{
    test: test_name
  } do
    goal = insert_goal("00000000-0000-4000-8000-000000000101")
    task = insert_task(goal, "00000000-0000-4000-8000-000000000201")
    run = request_run(goal, task, test_name)

    append_lifecycle(goal.id, run.id)

    assert {:ok, events} = Trajectory.replay(goal.id)
    assert {:ok, pure_state} = Projector.replay_events(events)
    assert pure_state.runs[run.id].status == :suspended
    assert pure_state.leases[@grant_id].status == :checkpoint_required
    assert pure_state.checkpoints[@checkpoint_id].stop_reason == "quota_refused"
    assert pure_state.capacity_snapshots[@snapshot_id].capacity_state == "observed"

    assert {:ok, position} =
             Projector.project(goal.id,
               clock: Shoestring.Test.FixedClock,
               identifier: Shoestring.Test.FixedIdentifier
             )

    assert position.last_sequence == 12
    assert Repo.get!(RunRecord, run.id).status == "suspended"
    assert Repo.get!(RunRecord, run.id).provider_session_id == "session-a"
    assert Repo.get!(ExecutionLeaseRecord, @grant_id).status == "checkpoint_required"
    assert Repo.get!(CheckpointRecord, @checkpoint_id).stop_reason == "quota_refused"
    assert Repo.get!(CapacitySnapshotRecord, @snapshot_id).capacity_state == "observed"
    assert Repo.aggregate(CapacityWindowRecord, :count, :id) == 1

    projection_before_rebuild = {
      Repo.get!(RunRecord, run.id).status,
      Repo.get!(ExecutionLeaseRecord, @grant_id).status,
      Repo.get!(CheckpointRecord, @checkpoint_id).next_action,
      Repo.get!(CapacitySnapshotRecord, @snapshot_id).scope
    }

    assert {:ok, rebuilt} =
             Projector.rebuild(goal.id,
               clock: Shoestring.Test.FixedClock,
               identifier: Shoestring.Test.FixedIdentifier
             )

    assert rebuilt.last_sequence == position.last_sequence

    assert {
             Repo.get!(RunRecord, run.id).status,
             Repo.get!(ExecutionLeaseRecord, @grant_id).status,
             Repo.get!(CheckpointRecord, @checkpoint_id).next_action,
             Repo.get!(CapacitySnapshotRecord, @snapshot_id).scope
           } == projection_before_rebuild
  end

  test "trusted run references are enforced at the selected goal boundary", %{test: test_name} do
    owner_goal = insert_goal("00000000-0000-4000-8000-000000000102")
    other_goal = insert_goal("00000000-0000-4000-8000-000000000103")
    task = insert_task(owner_goal, "00000000-0000-4000-8000-000000000202")
    run = request_run(owner_goal, task, test_name)

    assert {:error, {:trusted_reference_not_owned, :run_id}} =
             Trajectory.append(
               other_goal.id,
               %{
                 "type" => "run.starting",
                 "schema_version" => 1,
                 "actor" => "harness",
                 "occurred_at" => Shoestring.Test.FixedClock.now(),
                 "idempotency_key" => "foreign-run-#{test_name}",
                 "payload" => %{"run_id" => run.id}
               },
               trusted: [run_id: run.id]
             )
  end

  test "rebuild upcasts legacy v1 capacity events into fail-closed v2 projections", %{
    test: test_name
  } do
    goal = insert_goal("00000000-0000-4000-8000-000000000105")
    task = insert_task(goal, "00000000-0000-4000-8000-000000000204")
    run = request_run(goal, task, test_name)
    legacy_snapshot_id = "00000000-0000-4000-8000-000000000013"

    append(goal.id, run.id, "run.starting", %{"run_id" => run.id})

    append(goal.id, run.id, "run.running", %{
      "run_id" => run.id,
      "provider_session_id" => "legacy-session"
    })

    append(goal.id, run.id, "capacity.snapshot_observed", %{
      "snapshot_id" => legacy_snapshot_id,
      "run_id" => run.id,
      "contract_version" => 1,
      "capacity_state" => "known",
      "windows" => %{
        "items" => [%{"kind" => "five_hour", "state" => "known", "used_percent" => 25.0}]
      },
      "observed_at" => "2026-08-30T12:00:00Z",
      "expires_at" => "2026-08-30T12:05:00Z",
      "source" => %{"adapter_id" => "legacy.adapter", "method" => "probe"},
      "scope" => "account",
      "confidence" => "high",
      "support_tier" => "supported",
      "compatibility_state" => "compatible",
      "extensions" => %{}
    })

    assert {:ok, events} = Trajectory.replay(goal.id)
    assert {:ok, pure_state} = Projector.replay_events(events)
    assert pure_state.capacity_snapshots[legacy_snapshot_id].capacity_state == "degraded"

    assert {:ok, position} =
             Projector.project(goal.id,
               clock: Shoestring.Test.FixedClock,
               identifier: Shoestring.Test.FixedIdentifier
             )

    assert position.last_sequence == 4
    snapshot = Repo.get!(CapacitySnapshotRecord, legacy_snapshot_id)
    assert snapshot.contract_version == 2
    assert snapshot.capacity_state == "degraded"
    assert snapshot.source_provider_id == "legacy"
    assert snapshot.source_event == "none"
    assert snapshot.reason == "legacy_capacity_contract_missing_provenance"
    assert snapshot.confidence == "high"
    assert snapshot.support_tier == "conservative_partial"

    assert {:ok, rebuilt} =
             Projector.rebuild(goal.id,
               clock: Shoestring.Test.FixedClock,
               identifier: Shoestring.Test.FixedIdentifier
             )

    assert rebuilt.last_sequence == position.last_sequence
    assert Repo.get!(CapacitySnapshotRecord, legacy_snapshot_id).capacity_state == "degraded"
  end

  test "a late run.requested event cannot regress a projected running run", %{test: test_name} do
    goal = insert_goal("00000000-0000-4000-8000-000000000105")
    task = insert_task(goal, "00000000-0000-4000-8000-000000000205")
    run = request_run(goal, task, test_name)
    requested_event = Repo.get_by!(Shoestring.Trajectory.TrajectoryEvent, run_id: run.id)

    run
    |> RunRecord.projection_changeset(%{
      status: "running",
      projection_sequence: requested_event.sequence + 1,
      updated_at: Shoestring.Test.FixedClock.now()
    })
    |> Repo.update!()

    assert {:ok, _position} =
             Projector.project(goal.id,
               clock: Shoestring.Test.FixedClock,
               identifier: Shoestring.Test.FixedIdentifier
             )

    assert %RunRecord{status: "running"} = Repo.get!(RunRecord, run.id)
  end

  test "run intent uses injected deterministic identifiers and schema compatibility", %{
    test: test_name
  } do
    goal = insert_goal("00000000-0000-4000-8000-000000000104")
    task = insert_task(goal, "00000000-0000-4000-8000-000000000203")
    request = run_request(goal, task, test_name)
    identity = identity()

    assert {:ok, %RunRecord{id: @run_id}} =
             Runs.request(request, identity,
               clock: Shoestring.Test.FixedClock,
               identifier: Shoestring.Test.FixedIdentifier
             )

    incompatible = %{identity | schema_version: 2}

    assert {:error, %{category: :schema_incompatible, code: "run_request_version_incompatible"}} =
             Runs.request(request, incompatible,
               clock: Shoestring.Test.FixedClock,
               identifier: Shoestring.Test.FixedIdentifier
             )
  end

  defp append_lifecycle(goal_id, run_id) do
    append(goal_id, run_id, "run.starting", %{"run_id" => run_id})

    append(goal_id, run_id, "run.running", %{
      "run_id" => run_id,
      "provider_session_id" => "session-a"
    })

    append(
      goal_id,
      run_id,
      "capacity.snapshot_observed",
      %{
        "snapshot_id" => @snapshot_id,
        "run_id" => run_id,
        "contract_version" => 2,
        "capacity_state" => "observed",
        "windows" => %{
          "items" => [%{"kind" => "five_hour", "state" => "observed", "used_percent" => 25.0}]
        },
        "observed_at" => "2026-08-30T12:00:00Z",
        "expires_at" => "2026-08-30T12:05:00Z",
        "freshness" => %{"max_age_seconds" => 300},
        "source" => %{
          "adapter_id" => "test.adapter",
          "provider_id" => "codex",
          "invocation_mode" => "app_server",
          "event" => "explicit_read"
        },
        "scope" => "account",
        "confidence" => "high",
        "support_tier" => "proactive",
        "compatibility_state" => "compatible",
        "reason" => nil,
        "extensions" => %{}
      },
      2
    )

    append(goal_id, run_id, "lease.proposed", %{
      "grant_id" => @grant_id,
      "run_id" => run_id,
      "admitted_snapshot_id" => @snapshot_id,
      "contract_version" => 1,
      "reserves" => %{"response" => 1, "tool" => 1},
      "response_budget" => 4,
      "tool_budget" => 4,
      "deadline" => "2026-08-30T12:15:00Z",
      "checkpoint_cadence" => 2,
      "renewal_state" => "eligible",
      "extensions" => %{}
    })

    append(goal_id, run_id, "lease.granted", %{"grant_id" => @grant_id})
    append(goal_id, run_id, "lease.active", %{"grant_id" => @grant_id})
    append(goal_id, run_id, "lease.expired", %{"grant_id" => @grant_id})
    append(goal_id, run_id, "run.pausing", %{"run_id" => run_id})
    append(goal_id, run_id, "run.suspended", %{"run_id" => run_id})
    append(goal_id, run_id, "lease.checkpoint_required", %{"grant_id" => @grant_id})

    append(goal_id, run_id, "checkpoint.created", %{
      "checkpoint_id" => @checkpoint_id,
      "run_id" => run_id,
      "contract_version" => 1,
      "acceptance_contract" => %{"criteria" => ["Tests pass"]},
      "repository_state" => %{"revision" => "unknown", "dirty" => false},
      "evidence" => %{"items" => []},
      "decisions" => %{"items" => []},
      "unresolved_issues" => %{"items" => []},
      "next_action" => "Resume with a fresh lease.",
      "stop_reason" => "quota_refused",
      "artifact_ids" => %{"items" => []},
      "extensions" => %{}
    })
  end

  defp append(goal_id, run_id, type, payload, schema_version \\ 1) do
    assert {:ok, _event} =
             Trajectory.append(
               goal_id,
               %{
                 "type" => type,
                 "schema_version" => schema_version,
                 "actor" => "harness",
                 "occurred_at" => Shoestring.Test.FixedClock.now(),
                 "idempotency_key" => "#{type}:#{payload |> Map.values() |> inspect()}",
                 "payload" => payload
               },
               trusted: [run_id: run_id]
             )
  end

  defp request_run(goal, task, test_name) do
    assert {:ok, run} =
             Runs.request(run_request(goal, task, test_name), identity(),
               clock: Shoestring.Test.FixedClock,
               identifier: Shoestring.Test.FixedIdentifier
             )

    run
  end

  defp run_request(goal, task, test_name) do
    assert {:ok, request} =
             RunRequest.new(%{
               version: 1,
               goal_id: goal.id,
               task_id: task.id,
               workspace_ref: "workspace/project",
               prompt: "Run #{test_name}",
               policy: %{mode: "supervised", network: false, write_access: true},
               requested_capabilities: [],
               dispatch_id: "00000000-0000-4000-8000-000000000100",
               extensions: %{}
             })

    request
  end

  defp identity do
    assert {:ok, identity} =
             Identity.new(%{
               adapter_id: "test.adapter",
               provider: "test",
               adapter_version: "1.0.0",
               schema_version: 1,
               invocation_mode: :fake
             })

    identity
  end

  defp insert_goal(id) do
    %Goal{id: id}
    |> Goal.changeset(%{"title" => "Harness goal"})
    |> Ecto.Changeset.put_change(:owner_id, "00000000-0000-4000-8000-000000000301")
    |> Repo.insert!()
  end

  defp insert_task(goal, id) do
    %Task{id: id}
    |> Task.changeset(%{"title" => "Harness task"})
    |> Ecto.Changeset.put_change(:goal_id, goal.id)
    |> Repo.insert!()
  end
end
