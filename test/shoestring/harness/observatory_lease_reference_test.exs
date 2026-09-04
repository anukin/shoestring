defmodule Shoestring.Harness.ObservatoryLeaseReferenceTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.Harness.{
    CapacitySnapshot,
    ExecutionLeaseRecord,
    Observatory,
    Projector,
    RunRecord
  }

  alias Shoestring.Repo
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{Artifact, Goal, Task}

  @now ~U[2026-08-30 12:00:00.000000Z]

  defp insert_goal(title) do
    %Goal{}
    |> Goal.changeset(%{"title" => title})
    |> Ecto.Changeset.put_change(:owner_id, Ecto.UUID.generate())
    |> Repo.insert!()
  end

  defp insert_task(goal, title) do
    %Task{}
    |> Task.changeset(%{"title" => title})
    |> Ecto.Changeset.put_change(:goal_id, goal.id)
    |> Repo.insert!()
  end

  defp insert_run(goal, task) do
    run_id = Ecto.UUID.generate()
    dispatch_id = Ecto.UUID.generate()

    run =
      %RunRecord{
        id: run_id,
        goal_id: goal.id,
        task_id: task.id,
        dispatch_id: dispatch_id,
        provider_id: "codex",
        workspace_ref: "ws-1",
        request_version: 1,
        prompt: "Run prompt",
        continuation: %{},
        policy: %{"mode" => "supervised"},
        requested_capabilities: %{},
        status: "requested",
        projection_sequence: 0,
        inserted_at: @now,
        updated_at: @now
      }
      |> Repo.insert!()

    # Append canonical run.requested event
    attrs = %{
      "type" => "run.requested",
      "schema_version" => 1,
      "actor" => "harness",
      "occurred_at" => @now,
      "idempotency_key" => "run-req:#{run.id}",
      "payload" => %{
        "run_id" => run.id,
        "dispatch_id" => run.dispatch_id,
        "provider_id" => run.provider_id,
        "workspace_ref" => run.workspace_ref,
        "request_version" => run.request_version,
        "prompt" => run.prompt,
        "continuation" => run.continuation,
        "policy" => run.policy,
        "requested_capabilities" => run.requested_capabilities
      }
    }

    assert {:ok, _} =
             Trajectory.append(goal.id, attrs, trusted: [task_id: task.id, run_id: run.id])

    assert {:ok, _} = Projector.project(goal.id)

    run
  end

  defp make_snapshot(attrs \\ %{}) do
    defaults = %{
      version: 2,
      snapshot_id: Ecto.UUID.generate(),
      capacity_state: :observed,
      windows: [
        %{
          kind: "primary",
          state: :observed,
          used_percent: 20.0,
          reset_at: ~U[2026-08-30 13:00:00.000000Z]
        }
      ],
      observed_at: @now,
      freshness: %{max_age_seconds: 300},
      source: %{
        adapter_id: "fixture.capacity",
        provider_id: "codex",
        invocation_mode: "app_server",
        event: :explicit_read
      },
      scope: "account-1",
      confidence: :high,
      support_tier: :proactive,
      compatibility_state: :compatible,
      reason: nil,
      extensions: %{}
    }

    merged = Map.merge(defaults, attrs)
    validation_now = Map.get(merged, :observed_at) || @now
    {:ok, snapshot} = CapacitySnapshot.new(merged, now: validation_now)
    snapshot
  end

  describe "strict goal ownership boundary" do
    test "user run CANNOT reference an observatory-owned capacity snapshot (strict same-goal ownership enforced)" do
      goal_a = insert_goal("Goal A")
      task_a = insert_task(goal_a, "Task A")
      run_a = insert_run(goal_a, task_a)

      # Ingest a capacity snapshot into the protected observatory ledger
      observatory_snapshot = make_snapshot()
      assert {:ok, :persisted, _} = Observatory.ingest(observatory_snapshot, now: @now)

      # User Goal A proposes a lease referencing the observatory-owned snapshot
      grant_id = Ecto.UUID.generate()

      lease_event = %{
        "type" => "lease.proposed",
        "schema_version" => 1,
        "actor" => "harness",
        "occurred_at" => @now,
        "idempotency_key" => "lease-prop:#{grant_id}",
        "payload" => %{
          "grant_id" => grant_id,
          "run_id" => run_a.id,
          "admitted_snapshot_id" => observatory_snapshot.snapshot_id,
          "contract_version" => 1,
          "reserves" => %{"response" => 10, "tool" => 5},
          "response_budget" => 100,
          "tool_budget" => 50,
          "deadline" => DateTime.to_iso8601(~U[2026-08-30 12:30:00.000000Z]),
          "checkpoint_cadence" => 30,
          "renewal_state" => "eligible",
          "extensions" => %{}
        }
      }

      assert {:ok, _} = Trajectory.append(goal_a.id, lease_event, trusted: [run_id: run_a.id])

      # Projecting Goal A must fail because observatory snapshot is not owned by Goal A
      assert {:error,
              {:harness_projection_failed, _seq, {:lease_dependency_not_found, ^grant_id},
               _position}} =
               Projector.project(goal_a.id)

      # Lease was not inserted
      assert nil == Repo.get(ExecutionLeaseRecord, grant_id)
    end

    test "user run CANNOT reference a capacity snapshot owned by a different user goal" do
      goal_a = insert_goal("Goal A")
      task_a = insert_task(goal_a, "Task A")
      run_a = insert_run(goal_a, task_a)

      goal_b = insert_goal("Goal B")
      task_b = insert_task(goal_b, "Task B")
      run_b = insert_run(goal_b, task_b)

      # Append and project a capacity snapshot directly in Goal B (user goal)
      snapshot_b = make_snapshot()

      snap_event_b = %{
        "type" => "capacity.snapshot_observed",
        "schema_version" => 2,
        "actor" => "harness",
        "occurred_at" => @now,
        "idempotency_key" => "snap-b:#{snapshot_b.snapshot_id}",
        "payload" => %{
          "snapshot_id" => snapshot_b.snapshot_id,
          "contract_version" => 2,
          "capacity_state" => "observed",
          "windows" => %{
            "items" => [%{"kind" => "primary", "state" => "observed", "used_percent" => 10.0}]
          },
          "observed_at" => DateTime.to_iso8601(@now),
          "expires_at" => DateTime.to_iso8601(DateTime.add(@now, 300, :second)),
          "freshness" => %{"max_age_seconds" => 300},
          "source" => %{
            "adapter_id" => "fixture.capacity",
            "provider_id" => "codex",
            "invocation_mode" => "app_server",
            "event" => "explicit_read"
          },
          "scope" => "account-1",
          "confidence" => "high",
          "support_tier" => "proactive",
          "compatibility_state" => "compatible",
          "extensions" => %{}
        }
      }

      assert {:ok, _} = Trajectory.append(goal_b.id, snap_event_b, trusted: [run_id: run_b.id])
      assert {:ok, _} = Projector.project(goal_b.id)

      # Now User Goal A proposes a lease referencing Goal B's snapshot
      grant_id = Ecto.UUID.generate()

      cross_goal_lease_event = %{
        "type" => "lease.proposed",
        "schema_version" => 1,
        "actor" => "harness",
        "occurred_at" => @now,
        "idempotency_key" => "cross-lease:#{grant_id}",
        "payload" => %{
          "grant_id" => grant_id,
          "run_id" => run_a.id,
          "admitted_snapshot_id" => snapshot_b.snapshot_id,
          "contract_version" => 1,
          "reserves" => %{"response" => 10, "tool" => 5},
          "response_budget" => 100,
          "tool_budget" => 50,
          "deadline" => DateTime.to_iso8601(~U[2026-08-30 12:30:00.000000Z]),
          "checkpoint_cadence" => 30,
          "renewal_state" => "eligible",
          "extensions" => %{}
        }
      }

      assert {:ok, _} =
               Trajectory.append(goal_a.id, cross_goal_lease_event, trusted: [run_id: run_a.id])

      # Projecting Goal A must fail because snapshot belongs to Goal B, NOT Goal A or Observatory
      assert {:error,
              {:harness_projection_failed, _seq, {:lease_dependency_not_found, ^grant_id},
               _position}} =
               Projector.project(goal_a.id)

      # Lease was not inserted
      assert nil == Repo.get(ExecutionLeaseRecord, grant_id)
    end

    test "proposing a lease referencing a run owned by another goal fails" do
      goal_a = insert_goal("Goal A")
      task_a = insert_task(goal_a, "Task A")
      _run_a = insert_run(goal_a, task_a)

      goal_b = insert_goal("Goal B")
      task_b = insert_task(goal_b, "Task B")
      run_b = insert_run(goal_b, task_b)

      grant_id = Ecto.UUID.generate()
      observatory_snapshot = make_snapshot()
      assert {:ok, :persisted, _} = Observatory.ingest(observatory_snapshot, now: @now)

      bad_run_lease_event = %{
        "type" => "lease.proposed",
        "schema_version" => 1,
        "actor" => "harness",
        "occurred_at" => @now,
        "idempotency_key" => "bad-run-lease:#{grant_id}",
        "payload" => %{
          "grant_id" => grant_id,
          "run_id" => run_b.id,
          "admitted_snapshot_id" => observatory_snapshot.snapshot_id,
          "contract_version" => 1,
          "reserves" => %{"response" => 10, "tool" => 5},
          "response_budget" => 100,
          "tool_budget" => 50,
          "deadline" => DateTime.to_iso8601(~U[2026-08-30 12:30:00.000000Z]),
          "checkpoint_cadence" => 30,
          "renewal_state" => "eligible",
          "extensions" => %{}
        }
      }

      # 1. Trusted append boundary rejects run_id not owned by Goal A
      assert {:error, {:trusted_reference_not_owned, :run_id}} =
               Trajectory.append(goal_a.id, bad_run_lease_event, trusted: [run_id: run_b.id])

      # 2. Untrusted append also fails projection if run is not owned by Goal A
      assert {:ok, _} = Trajectory.append(goal_a.id, bad_run_lease_event)

      assert {:error,
              {:harness_projection_failed, _seq, {:lease_dependency_not_found, ^grant_id},
               _position}} =
               Projector.project(goal_a.id)
    end

    test "creating a checkpoint referencing an artifact owned by another goal fails" do
      goal_a = insert_goal("Goal A")
      task_a = insert_task(goal_a, "Task A")
      run_a = insert_run(goal_a, task_a)

      goal_b = insert_goal("Goal B")
      task_b = insert_task(goal_b, "Task B")

      artifact_b =
        %Artifact{
          id: Ecto.UUID.generate(),
          goal_id: goal_b.id,
          task_id: task_b.id,
          sha256: String.duplicate("b", 64),
          byte_size: 100,
          media_type: "text/plain",
          location: "artifacts/b.txt",
          inserted_at: @now,
          updated_at: @now
        }
        |> Repo.insert!()

      checkpoint_id = Ecto.UUID.generate()

      bad_artifact_checkpoint_event = %{
        "type" => "checkpoint.created",
        "schema_version" => 1,
        "actor" => "harness",
        "occurred_at" => @now,
        "idempotency_key" => "bad-cp:#{checkpoint_id}",
        "payload" => %{
          "checkpoint_id" => checkpoint_id,
          "run_id" => run_a.id,
          "contract_version" => 1,
          "acceptance_contract" => %{"status" => "pending"},
          "repository_state" => %{"commit" => "abc"},
          "evidence" => %{},
          "decisions" => %{},
          "unresolved_issues" => %{},
          "next_action" => "proceed",
          "stop_reason" => "budget",
          "artifact_ids" => %{"items" => [artifact_b.id]},
          "extensions" => %{}
        }
      }

      assert {:ok, _} =
               Trajectory.append(goal_a.id, bad_artifact_checkpoint_event,
                 trusted: [run_id: run_a.id]
               )

      assert {:error,
              {:harness_projection_failed, _seq, {:artifact_not_owned, bad_artifact_id}, _pos}} =
               Projector.project(goal_a.id)

      assert bad_artifact_id == artifact_b.id
    end

    test "observatory rebuild and arbitrary stream projection order remain deterministic and recoverable" do
      # 1. Ingest historical observations into the observatory ledger
      snap1 = make_snapshot(%{observed_at: @now})
      assert {:ok, :persisted, _} = Observatory.ingest(snap1, now: @now)

      snap2 =
        make_snapshot(%{
          observed_at: DateTime.add(@now, 60, :second),
          windows: [
            %{
              kind: "primary",
              state: :observed,
              used_percent: 50.0,
              reset_at: ~U[2026-08-30 14:00:00.000000Z]
            }
          ]
        })

      assert {:ok, :persisted, _} =
               Observatory.ingest(snap2, now: DateTime.add(@now, 60, :second))

      # 2. User Goal A has its own run, capacity snapshot, and lease
      goal_a = insert_goal("Goal A")
      task_a = insert_task(goal_a, "Task A")
      run_a = insert_run(goal_a, task_a)

      snap_a = make_snapshot()

      snap_event_a = %{
        "type" => "capacity.snapshot_observed",
        "schema_version" => 2,
        "actor" => "harness",
        "occurred_at" => @now,
        "idempotency_key" => "snap-a:#{snap_a.snapshot_id}",
        "payload" => %{
          "snapshot_id" => snap_a.snapshot_id,
          "contract_version" => 2,
          "capacity_state" => "observed",
          "windows" => %{
            "items" => [%{"kind" => "primary", "state" => "observed", "used_percent" => 15.0}]
          },
          "observed_at" => DateTime.to_iso8601(@now),
          "expires_at" => DateTime.to_iso8601(DateTime.add(@now, 300, :second)),
          "freshness" => %{"max_age_seconds" => 300},
          "source" => %{
            "adapter_id" => "fixture.capacity",
            "provider_id" => "codex",
            "invocation_mode" => "app_server",
            "event" => "explicit_read"
          },
          "scope" => "account-1",
          "confidence" => "high",
          "support_tier" => "proactive",
          "compatibility_state" => "compatible",
          "extensions" => %{}
        }
      }

      assert {:ok, _} = Trajectory.append(goal_a.id, snap_event_a, trusted: [run_id: run_a.id])

      grant_id_a = Ecto.UUID.generate()

      lease_event_a = %{
        "type" => "lease.proposed",
        "schema_version" => 1,
        "actor" => "harness",
        "occurred_at" => @now,
        "idempotency_key" => "lease-prop:#{grant_id_a}",
        "payload" => %{
          "grant_id" => grant_id_a,
          "run_id" => run_a.id,
          "admitted_snapshot_id" => snap_a.snapshot_id,
          "contract_version" => 1,
          "reserves" => %{"response" => 10, "tool" => 5},
          "response_budget" => 100,
          "tool_budget" => 50,
          "deadline" => DateTime.to_iso8601(~U[2026-08-30 12:30:00.000000Z]),
          "checkpoint_cadence" => 30,
          "renewal_state" => "eligible",
          "extensions" => %{}
        }
      }

      assert {:ok, _} = Trajectory.append(goal_a.id, lease_event_a, trusted: [run_id: run_a.id])
      assert {:ok, _} = Projector.project(goal_a.id)

      # 3. Rebuild Observatory projection under historical data:
      # Must succeed cleanly without FK restrict errors
      assert {:ok, _pos} = Observatory.rebuild()

      # Verify observatory observations were completely reconstructed
      assert length(Observatory.latest_observations()) > 0

      # 4. Independent projection order: Project Goal A again, then Observatory, both succeed
      assert {:ok, _} = Projector.project(goal_a.id)
      assert {:ok, _} = Observatory.reconcile()
    end
  end
end
