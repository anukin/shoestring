defmodule Shoestring.Harness.ObservatoryTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.Harness.{
    CapacitySnapshot,
    CapacitySnapshotRecord,
    Observatory,
    Projector
  }

  alias Shoestring.Repo
  alias Shoestring.Trajectory.{Goal, TrajectoryEvent}

  @t0 ~U[2026-08-30 12:00:00.000000Z]
  @t1 ~U[2026-08-30 12:00:30.000000Z]
  @t_stale ~U[2026-08-30 12:05:01.000000Z]

  defp make_snapshot(attrs \\ %{}) do
    defaults = %{
      version: 2,
      snapshot_id: Ecto.UUID.generate(),
      capacity_state: :observed,
      windows: [
        %{
          kind: "primary",
          state: :observed,
          used_percent: 25.0,
          reset_at: ~U[2026-08-30 13:00:00Z]
        },
        %{
          kind: "secondary",
          state: :observed,
          used_percent: 40.0,
          reset_at: ~U[2026-09-06 12:00:00Z]
        }
      ],
      observed_at: @t0,
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
    {:ok, snapshot} = CapacitySnapshot.new(merged, now: merged[:observed_at] || @t0)
    snapshot
  end

  describe "singleton identity, provisioning, and protection" do
    test "provisions the singleton goal idempotently and survives re-provisioning" do
      goal_id = Observatory.observatory_goal_id()
      owner_id = Observatory.observatory_owner_id()

      assert {:ok, %Goal{id: ^goal_id, owner_id: ^owner_id, status: "protected"}} =
               Observatory.ensure_provisioned()

      # Calling again returns the existing goal idempotently
      assert {:ok, %Goal{id: ^goal_id}} = Observatory.ensure_provisioned()

      # Helper correctly identifies the observatory
      assert Observatory.observatory_goal?(goal_id)
      assert Goal.observatory?(goal_id)
      assert Goal.observatory?(%Goal{id: goal_id, status: "protected"})
      refute Goal.observatory?(Ecto.UUID.generate())
      refute Goal.observatory?(nil)
    end

    test "user_goals query scope excludes the protected observatory singleton" do
      {:ok, observatory_goal} = Observatory.ensure_provisioned()

      user_goal =
        %Goal{}
        |> Goal.changeset(%{"title" => "Normal User Goal"})
        |> Ecto.Changeset.put_change(:owner_id, Ecto.UUID.generate())
        |> Repo.insert!()

      user_goals = Repo.all(Goal.user_goals())
      user_goal_ids = Enum.map(user_goals, & &1.id)

      assert user_goal.id in user_goal_ids
      refute observatory_goal.id in user_goal_ids
    end

    test "Goal.changeset protects observatory goal from ordinary user updates" do
      {:ok, observatory_goal} = Observatory.ensure_provisioned()

      changeset = Goal.changeset(observatory_goal, %{"title" => "Tampered Title"})
      refute changeset.valid?
      assert "protected observatory goal cannot be modified" in errors_on(changeset).base
    end

    test "Goal.create_changeset prevents creating user goals with observatory owner" do
      changeset =
        Goal.create_changeset(%Goal{}, Observatory.observatory_owner_id(), %{
          "title" => "Impostor Goal"
        })

      refute changeset.valid?

      assert "cannot create goal with protected observatory owner" in errors_on(changeset).owner_id
    end

    test "ensure_provisioned refuses to adopt pre-existing conflicting goal" do
      reserved_id = Observatory.observatory_goal_id()
      victim_owner = Ecto.UUID.generate()

      Repo.query!("DROP TRIGGER IF EXISTS protect_observatory_goal_delete")
      Repo.query!("DROP TRIGGER IF EXISTS protect_observatory_goal_update")
      Repo.delete_all(from g in Goal, where: g.id == ^reserved_id)

      _conflicting =
        %Goal{
          id: reserved_id,
          owner_id: victim_owner,
          title: "Victim Goal",
          status: "active",
          inserted_at: @t0,
          updated_at: @t0
        }
        |> Repo.insert!()

      assert {:error, {:conflicting_goal_at_observatory_id, found}} =
               Observatory.ensure_provisioned()

      assert found.id == reserved_id
      assert found.owner_id == victim_owner
      assert found.status == "active"
    end

    test "Goal.changeset closes bypasses with field-specific errors and allows victim row updates" do
      reserved_id = Observatory.observatory_goal_id()
      observatory_owner = Observatory.observatory_owner_id()
      user_id = Ecto.UUID.generate()

      # 1. Attempting to create goal with reserved ID via create_changeset
      cs1 = Goal.create_changeset(%Goal{id: reserved_id}, user_id, %{"title" => "Normal"})
      refute cs1.valid?
      assert "cannot use protected observatory goal id" in errors_on(cs1).id

      # Also attempting to set ID via put_change followed by changeset validation
      cs1_change =
        %Goal{}
        |> Goal.changeset(%{"title" => "Normal"})
        |> Ecto.Changeset.put_change(:id, reserved_id)
        |> Goal.changeset(%{})

      refute cs1_change.valid?
      assert "cannot use protected observatory goal id" in errors_on(cs1_change).id

      # 2. Attempting to assign reserved owner on new goal
      cs2 =
        %Goal{}
        |> Goal.changeset(%{"title" => "Normal"})
        |> Ecto.Changeset.put_change(:owner_id, observatory_owner)
        |> Goal.changeset(%{})

      refute cs2.valid?
      assert "cannot create goal with protected observatory owner" in errors_on(cs2).owner_id

      # 3. Attempting to assign protected status on new goal
      cs3 =
        %Goal{}
        |> Goal.changeset(%{"title" => "Normal", "status" => "protected"})

      refute cs3.valid?
      assert "cannot use protected status" in errors_on(cs3).status

      # 4. Updating a victim user goal (holding reserved_id but user owner and active status) is allowed
      victim =
        %Goal{
          id: reserved_id,
          owner_id: user_id,
          title: "Victim",
          status: "active"
        }
        |> Ecto.put_meta(state: :loaded)

      cs4 = Goal.changeset(victim, %{"title" => "Victim Updated"})
      assert cs4.valid?
      assert Ecto.Changeset.get_change(cs4, :title) == "Victim Updated"
    end

    test "user_goals query scope does not hide a victim user row sharing reserved ID" do
      reserved_id = Observatory.observatory_goal_id()
      victim_owner = Ecto.UUID.generate()

      victim = %Goal{
        id: reserved_id,
        owner_id: victim_owner,
        title: "Victim User Goal",
        status: "active",
        inserted_at: @t0,
        updated_at: @t0
      }

      Repo.query!("DROP TRIGGER IF EXISTS protect_observatory_goal_delete")
      Repo.query!("DROP TRIGGER IF EXISTS protect_observatory_goal_update")
      Repo.delete_all(from g in Goal, where: g.id == ^reserved_id)
      Repo.insert!(victim)

      user_goals = Repo.all(Goal.user_goals())
      assert Enum.any?(user_goals, &(&1.id == reserved_id and &1.title == "Victim User Goal"))
    end
  end

  describe "ingestion, canonical event, and projection" do
    test "ingesting a valid snapshot appends canonical event and projects into records" do
      snapshot = make_snapshot()

      assert {:ok, :persisted, persisted_snap} = Observatory.ingest(snapshot, now: @t0)
      assert persisted_snap.snapshot_id == snapshot.snapshot_id

      goal_id = Observatory.observatory_goal_id()

      # 1. Canonical trajectory event was appended
      events = Repo.all(from e in TrajectoryEvent, where: e.goal_id == ^goal_id)
      assert length(events) == 1
      [event] = events

      assert event.type == "capacity.snapshot_observed"
      assert event.schema_version == 2
      assert event.sequence == 1
      assert event.payload["snapshot_id"] == snapshot.snapshot_id
      assert event.payload["contract_version"] == 2
      assert event.payload["capacity_state"] == "observed"
      assert event.payload["source"]["provider_id"] == "codex"
      assert event.payload["source"]["invocation_mode"] == "app_server"
      assert event.payload["source"]["event"] == "explicit_read"

      # 2. Projected into database records
      record = Repo.get(CapacitySnapshotRecord, snapshot.snapshot_id) |> Repo.preload(:windows)
      assert record != nil
      assert record.goal_id == goal_id
      assert record.capacity_state == "observed"
      assert record.source_provider_id == "codex"
      assert record.source_invocation_mode == "app_server"
      assert record.source_event == "explicit_read"
      assert record.confidence == "high"
      assert record.support_tier == "proactive"
      assert record.compatibility_state == "compatible"
      assert length(record.windows) == 2

      primary_window = Enum.find(record.windows, &(&1.kind == "primary"))
      assert primary_window.state == "observed"
      assert primary_window.used_percent == 25.0
      assert primary_window.unknown_reason == nil

      secondary_window = Enum.find(record.windows, &(&1.kind == "secondary"))
      assert secondary_window.state == "observed"
      assert secondary_window.used_percent == 40.0
    end

    test "ingest accepts map attributes and validates contract" do
      attrs = %{
        version: 2,
        snapshot_id: Ecto.UUID.generate(),
        capacity_state: :observed,
        windows: [
          %{kind: "primary", state: :observed, used_percent: 50.0}
        ],
        observed_at: @t0,
        freshness: %{max_age_seconds: 300},
        source: %{
          adapter_id: "fixture.capacity",
          provider_id: "codex",
          invocation_mode: "app_server",
          event: :explicit_read
        },
        scope: "account-map",
        confidence: :high,
        support_tier: :proactive,
        compatibility_state: :compatible,
        reason: nil,
        extensions: %{}
      }

      assert {:ok, :persisted, snapshot} = Observatory.ingest(attrs, now: @t0)
      assert snapshot.scope == "account-map"

      # Invalid map fails validation
      invalid = Map.put(attrs, :capacity_state, :unknown)
      assert {:error, _changeset} = Observatory.ingest(invalid, now: @t0)
    end

    test "truthful state when event append succeeds but projection fails, and deterministic rebuild path" do
      goal_id = Observatory.observatory_goal_id()
      {:ok, _goal} = Observatory.ensure_provisioned()

      # Simulate a failed projector state for the observatory goal
      failed_position = %Shoestring.Trajectory.ProjectorPosition{
        id: Ecto.UUID.generate(),
        goal_id: goal_id,
        projector: "harness",
        version: 1,
        last_sequence: 0,
        status: "failed",
        error_detail: "simulated_projection_failure"
      }

      Repo.insert!(failed_position)

      snapshot = make_snapshot(%{scope: "truthful-failure"})

      # Ingest must report truthful state: event was appended, but projection failed
      assert {:error, {:projection_failed, event, error}} =
               Observatory.ingest(snapshot, now: @t0)

      assert event.type == "capacity.snapshot_observed"

      assert match?(
               {:harness_projection_failed, _seq,
                {:projection_failed_detail, "simulated_projection_failure"}, _pos},
               error
             )

      # Deterministic reconciliation/rebuild path restores the projection
      assert {:ok, _pos} = Observatory.rebuild()

      rebuilt_snap =
        Observatory.get_latest_observation(
          snapshot.source.provider_id,
          snapshot.source.invocation_mode,
          snapshot.scope
        )

      assert rebuilt_snap != nil
      assert rebuilt_snap.snapshot_id == snapshot.snapshot_id
    end

    test "concurrent equivalent ingest is idempotent and writes exactly one event (Task.async_stream)" do
      snapshots =
        for _i <- 1..10 do
          make_snapshot(%{
            snapshot_id: Ecto.UUID.generate(),
            scope: "concurrent-test-scope",
            observed_at: @t0
          })
        end

      results =
        Task.async_stream(
          snapshots,
          fn snap -> Observatory.ingest(snap, now: @t0) end,
          max_concurrency: 10,
          timeout: :infinity
        )
        |> Enum.to_list()

      for {:ok, res} <- results do
        assert match?({:ok, status, _snap} when status in [:persisted, :deduplicated], res)
      end

      # Exactly ONE event in trajectory
      goal_id = Observatory.observatory_goal_id()

      events =
        Repo.all(
          from e in TrajectoryEvent,
            where: e.goal_id == ^goal_id and e.payload["scope"] == "concurrent-test-scope"
        )

      assert length(events) == 1

      # Exactly ONE snapshot record in database
      records =
        Repo.all(
          from s in CapacitySnapshotRecord,
            where: s.goal_id == ^goal_id and s.scope == "concurrent-test-scope"
        )

      assert length(records) == 1
    end
  end

  describe "semantic deduplication" do
    test "repeated equivalent high-frequency reading does not grow the ledger" do
      snapshot1 = make_snapshot(%{observed_at: @t0})
      assert {:ok, :persisted, _} = Observatory.ingest(snapshot1, now: @t0)

      goal_id = Observatory.observatory_goal_id()
      assert 1 == Repo.aggregate(from(e in TrajectoryEvent, where: e.goal_id == ^goal_id), :count)

      # Ingest reading with identical metrics 30 seconds later (high-frequency poll)
      snapshot2 = make_snapshot(%{observed_at: @t1})
      assert {:ok, :deduplicated, deduplicated} = Observatory.ingest(snapshot2, now: @t1)

      # Preserves original snapshot id and timestamp
      assert deduplicated.snapshot_id == snapshot1.snapshot_id
      assert deduplicated.observed_at == snapshot1.observed_at

      # Ledger did not grow!
      assert 1 == Repo.aggregate(from(e in TrajectoryEvent, where: e.goal_id == ^goal_id), :count)
    end

    test "reading with changed used_percent is persisted" do
      snapshot1 = make_snapshot()
      assert {:ok, :persisted, _} = Observatory.ingest(snapshot1, now: @t0)

      snapshot2 =
        make_snapshot(%{
          observed_at: @t1,
          windows: [
            %{
              kind: "primary",
              state: :observed,
              used_percent: 26.0,
              reset_at: ~U[2026-08-30 13:00:00Z]
            },
            %{
              kind: "secondary",
              state: :observed,
              used_percent: 40.0,
              reset_at: ~U[2026-09-06 12:00:00Z]
            }
          ]
        })

      assert {:ok, :persisted, persisted2} = Observatory.ingest(snapshot2, now: @t1)
      assert persisted2.snapshot_id == snapshot2.snapshot_id

      goal_id = Observatory.observatory_goal_id()
      assert 2 == Repo.aggregate(from(e in TrajectoryEvent, where: e.goal_id == ^goal_id), :count)
    end

    test "reading with changed reset_at is persisted" do
      snapshot1 = make_snapshot()
      assert {:ok, :persisted, _} = Observatory.ingest(snapshot1, now: @t0)

      snapshot2 =
        make_snapshot(%{
          observed_at: @t1,
          windows: [
            %{
              kind: "primary",
              state: :observed,
              used_percent: 25.0,
              reset_at: ~U[2026-08-30 14:00:00Z]
            },
            %{
              kind: "secondary",
              state: :observed,
              used_percent: 40.0,
              reset_at: ~U[2026-09-06 12:00:00Z]
            }
          ]
        })

      assert {:ok, :persisted, persisted2} = Observatory.ingest(snapshot2, now: @t1)
      assert persisted2.snapshot_id == snapshot2.snapshot_id

      goal_id = Observatory.observatory_goal_id()
      assert 2 == Repo.aggregate(from(e in TrajectoryEvent, where: e.goal_id == ^goal_id), :count)
    end

    test "reading with changed source event is persisted" do
      snapshot1 = make_snapshot()
      assert {:ok, :persisted, _} = Observatory.ingest(snapshot1, now: @t0)

      snapshot2 =
        make_snapshot(%{
          observed_at: @t1,
          source: %{
            adapter_id: "fixture.capacity",
            provider_id: "codex",
            invocation_mode: "app_server",
            event: :update_notification
          }
        })

      assert {:ok, :persisted, persisted2} = Observatory.ingest(snapshot2, now: @t1)
      assert persisted2.snapshot_id == snapshot2.snapshot_id

      goal_id = Observatory.observatory_goal_id()
      assert 2 == Repo.aggregate(from(e in TrajectoryEvent, where: e.goal_id == ^goal_id), :count)
    end

    test "transitioning to refused capacity is persisted" do
      snapshot1 = make_snapshot()
      assert {:ok, :persisted, _} = Observatory.ingest(snapshot1, now: @t0)

      refusal_attrs = %{
        version: 2,
        snapshot_id: Ecto.UUID.generate(),
        capacity_state: :refused,
        windows: [
          %{kind: "primary", state: :unknown, reason: "limit_exceeded"}
        ],
        observed_at: nil,
        freshness: %{max_age_seconds: 300},
        source: %{
          adapter_id: "fixture.capacity",
          provider_id: "codex",
          invocation_mode: "app_server",
          event: :explicit_read
        },
        scope: "account-1",
        confidence: :medium,
        support_tier: :proactive,
        compatibility_state: :compatible,
        reason: "rate_limit_reached",
        extensions: %{}
      }

      {:ok, refusal_snapshot} = CapacitySnapshot.new(refusal_attrs, now: @t1)

      assert {:ok, :persisted, _} = Observatory.ingest(refusal_snapshot, now: @t1)

      goal_id = Observatory.observatory_goal_id()
      assert 2 == Repo.aggregate(from(e in TrajectoryEvent, where: e.goal_id == ^goal_id), :count)
    end

    test "reading is persisted when freshness transitions from fresh to stale" do
      # Snapshot 1 was observed at @t0 with max_age 300s (expires at 12:05:00)
      snapshot1 = make_snapshot(%{observed_at: @t0, freshness: %{max_age_seconds: 300}})
      assert {:ok, :persisted, _} = Observatory.ingest(snapshot1, now: @t0)

      # At @t_stale (12:05:01), snapshot 1 has transitioned to :stale.
      # A new reading taken at @t_stale is fresh (:fresh vs :stale).
      snapshot2 = make_snapshot(%{observed_at: @t_stale, freshness: %{max_age_seconds: 300}})

      assert {:ok, :persisted, _} = Observatory.ingest(snapshot2, now: @t_stale)

      goal_id = Observatory.observatory_goal_id()
      assert 2 == Repo.aggregate(from(e in TrajectoryEvent, where: e.goal_id == ^goal_id), :count)
    end
  end

  describe "restart, replay, and projection rebuild" do
    test "projector rebuild from trajectory events preserves true original timestamps and age" do
      snapshot = make_snapshot(%{observed_at: @t0})
      assert {:ok, :persisted, _} = Observatory.ingest(snapshot, now: @t0)

      goal_id = Observatory.observatory_goal_id()

      # Simulate rebuild (e.g. after crash / restart)
      assert {:ok, _position} = Projector.rebuild(goal_id)

      # Fetch re-projected snapshot from query API
      assert {:ok, loaded} = Observatory.latest_observation("codex", "app_server", "account-1")
      assert loaded.snapshot_id == snapshot.snapshot_id
      assert loaded.observed_at == @t0

      # At t0 + 120s, calculated age is 120 seconds, NOT 0 seconds!
      summary = Observatory.observation_summary(loaded, now: ~U[2026-08-30 12:02:00Z])
      assert summary.age_seconds == 120
      assert summary.freshness_state == :fresh
      assert summary.eligible? == true
    end
  end

  describe "query API and fail-closed automation eligibility" do
    test "observation_summary returns exact windows without fake 0% values" do
      attrs = %{
        version: 2,
        snapshot_id: Ecto.UUID.generate(),
        capacity_state: :degraded,
        windows: [
          %{kind: "primary", state: :observed, used_percent: 25.0},
          %{kind: "secondary", state: :unknown, reason: "bucket_absent"}
        ],
        observed_at: @t0,
        freshness: %{max_age_seconds: 300},
        source: %{
          adapter_id: "fixture.capacity",
          provider_id: "claude",
          invocation_mode: "interactive_status_line",
          event: :status_line_input
        },
        scope: "claude-scope",
        confidence: :medium,
        support_tier: :conservative_partial,
        compatibility_state: :degraded,
        reason: "partial_telemetry",
        extensions: %{}
      }

      {:ok, snapshot} = CapacitySnapshot.new(attrs, now: @t0)
      assert {:ok, :persisted, _} = Observatory.ingest(snapshot, now: @t0)

      assert {:ok, loaded} =
               Observatory.latest_observation("claude", "interactive_status_line", "claude-scope")

      summary = Observatory.observation_summary(loaded, now: @t0)

      assert summary.provider_id == "claude"
      assert summary.invocation_mode == "interactive_status_line"
      assert summary.scope == "claude-scope"
      assert summary.capacity_state == :degraded
      assert summary.support_tier == :conservative_partial
      assert summary.confidence == :medium
      assert summary.reason == "partial_telemetry"

      # Fail-closed automation eligibility: degraded and conservative_partial are NOT eligible
      refute summary.eligible?

      # Verify no fake 0% on unknown window
      primary = Enum.find(summary.windows, &(&1.kind == "primary"))
      assert primary.state == :observed
      assert primary.used_percent == 25.0

      secondary = Enum.find(summary.windows, &(&1.kind == "secondary"))
      assert secondary.state == :unknown
      assert secondary.used_percent == nil
      assert secondary.reason == "bucket_absent"
    end

    test "latest_observations lists latest snapshots across scopes" do
      snap1 = make_snapshot(%{scope: "scope-a", observed_at: @t0})
      snap2 = make_snapshot(%{scope: "scope-b", observed_at: @t0})

      assert {:ok, :persisted, _} = Observatory.ingest(snap1, now: @t0)
      assert {:ok, :persisted, _} = Observatory.ingest(snap2, now: @t0)

      all = Observatory.latest_observations()
      scopes = Enum.map(all, & &1.scope)

      assert "scope-a" in scopes
      assert "scope-b" in scopes
    end

    test "unknown scope returns :not_found and nil respectively" do
      assert {:error, :not_found} =
               Observatory.latest_observation("unknown", "none", "nonexistent")

      assert nil == Observatory.get_latest_observation("unknown", "none", "nonexistent")
    end

    test "current observation selection orders by provider observation time, not projection sequence (B6)" do
      # Ingest a newer observation observed at @t1
      newer_snap =
        make_snapshot(%{
          scope: "b6-scope",
          observed_at: @t1,
          windows: [
            %{
              kind: "primary",
              state: :observed,
              used_percent: 75.0,
              reset_at: ~U[2026-08-30 13:00:00Z]
            }
          ]
        })

      assert {:ok, :persisted, _} = Observatory.ingest(newer_snap, now: @t1)

      # Ingest an out-of-order historical observation observed at @t0 (earlier time, but later projection)
      older_historical_snap =
        make_snapshot(%{
          scope: "b6-scope",
          observed_at: @t0,
          windows: [
            %{
              kind: "primary",
              state: :observed,
              used_percent: 10.0,
              reset_at: ~U[2026-08-30 13:00:00Z]
            }
          ]
        })

      assert {:ok, :persisted, _} = Observatory.ingest(older_historical_snap, now: @t1)

      # Both events exist in trajectory and projection
      goal_id = Observatory.observatory_goal_id()

      assert length(
               Repo.all(
                 from e in TrajectoryEvent,
                   where: e.goal_id == ^goal_id and e.payload["scope"] == "b6-scope"
               )
             ) == 2

      # Query must order by provider observation time: returning newer_snap (75.0% used), NOT older_historical_snap!
      latest =
        Observatory.get_latest_observation(
          newer_snap.source.provider_id,
          newer_snap.source.invocation_mode,
          "b6-scope"
        )

      assert latest != nil
      assert latest.snapshot_id == newer_snap.snapshot_id
      assert DateTime.compare(latest.observed_at, @t1) == :eq

      # latest_observations must also select newer_snap for b6-scope
      all = Observatory.latest_observations()
      b6_entry = Enum.find(all, &(&1.scope == "b6-scope"))
      assert b6_entry != nil
      assert b6_entry.snapshot_id == newer_snap.snapshot_id
    end

    test "latest_observations bounds results and get_latest_observation uses index without temp sort (B5)" do
      # Ingest snapshots across multiple scopes
      for i <- 1..5 do
        snap =
          make_snapshot(%{
            scope: "bounded-scope-#{i}",
            observed_at: @t0
          })

        assert {:ok, :persisted, _} = Observatory.ingest(snap, now: @t0)
      end

      # Bounded query: limit 2
      bounded = Observatory.latest_observations(limit: 2)
      assert length(bounded) == 2

      # Verify query plan for get_latest_observation: uses index and avoids temp b-tree sorts
      goal_id = Observatory.observatory_goal_id()

      {:ok, %{rows: plan_rows}} =
        Repo.query(
          """
          EXPLAIN QUERY PLAN
          SELECT id FROM harness_capacity_snapshots
          WHERE goal_id = ?
            AND source_provider_id = ?
            AND source_invocation_mode = ?
            AND scope = ?
          ORDER BY observed_at_v2 DESC, projection_sequence DESC, id DESC
          LIMIT 1
          """,
          [goal_id, "codex", "app_server", "bounded-scope-1"]
        )

      plan_text =
        plan_rows
        |> Enum.map(&Enum.join(&1, " "))
        |> Enum.join("\n")

      # Plan must use the covering/lookup index
      assert String.contains?(plan_text, "harness_capacity_snapshots_observatory_lookup_idx")
      # Plan must NOT require a temporary sort B-tree
      refute String.contains?(plan_text, "TEMP B-TREE")
    end
  end
end
