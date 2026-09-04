defmodule Shoestring.Harness.Capacity.ClaudeMonitorTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.Harness.{
    CapacitySnapshot,
    ClaudeMonitor
  }

  alias Shoestring.Harness.Capacity.ClaudeMonitor, as: CapacityClaudeMonitor
  alias Shoestring.Harness.Capacity.Fixtures, as: CapacityFixtures

  @live_eval_time ~U[2026-08-29 07:34:25Z]
  @official_eval_time ~U[2026-08-29 04:30:10Z]
  @concurrent_eval_time ~U[2026-08-29 07:36:20Z]

  # Injectable test clock supporting dynamic time updates
  defmodule TestClock do
    def now(agent) do
      Agent.get(agent, & &1)
    end

    def set(agent, %DateTime{} = dt) do
      Agent.update(agent, fn _ -> dt end)
    end
  end

  setup do
    {:ok, clock_agent} = Agent.start_link(fn -> @live_eval_time end)
    clock_fn = fn -> TestClock.now(clock_agent) end

    %{
      clock_agent: clock_agent,
      clock_fn: clock_fn
    }
  end

  describe "supervised startup and proof of no external CLI / model call" do
    test "starts under supervision cleanly with default settings", %{clock_fn: clock_fn} do
      monitor =
        start_supervised!(
          {CapacityClaudeMonitor,
           [
             name: nil,
             version: "2.1.251",
             clock: clock_fn,
             scope: "test-session"
           ]}
        )

      assert is_pid(monitor)
      assert {:ok, snapshot} = CapacityClaudeMonitor.current_snapshot(monitor)
      assert snapshot.capacity_state == :unknown
      assert snapshot.support_tier == :conservative_partial
    end

    test "proves no external CLI or model call occurs during monitor operations", %{
      clock_fn: clock_fn
    } do
      test_pid = self()

      runner_spy = fn cmd, args, _opts ->
        send(test_pid, {:cli_invoked, cmd, args})
        {"claude 2.1.251", 0}
      end

      monitor =
        start_supervised!(
          {CapacityClaudeMonitor,
           [
             name: nil,
             runner: runner_spy,
             clock: clock_fn,
             scope: "passive-session"
           ]}
        )

      _ = :sys.get_state(monitor)

      # Only version discovery is permitted on startup
      assert_received {:cli_invoked, "claude", ["--version"]}
      refute_received {:cli_invoked, _, _}

      # Receiving callbacks, checking status, and disconnecting never invokes the CLI
      fixture = CapacityFixtures.load_fixture!("claude/status-line-single-live.json")
      assert {:ok, _status, _snap} = CapacityClaudeMonitor.receive_status_line(monitor, fixture)
      assert %{status: :degraded} = CapacityClaudeMonitor.status(monitor)
      assert {:ok, _snap} = CapacityClaudeMonitor.disconnect(monitor)

      # Verify that NO subsequent CLI commands were executed
      refute_received {:cli_invoked, _, _}
    end
  end

  describe "first-response boundary and absent rate limits" do
    test "reports unknown conservative-partial with exact reason before first response", %{
      clock_agent: clock_agent,
      clock_fn: clock_fn
    } do
      TestClock.set(clock_agent, @official_eval_time)

      monitor =
        start_supervised!(
          {CapacityClaudeMonitor,
           [
             name: nil,
             version: "2.1.251",
             clock: clock_fn,
             scope: "pre-response-session"
           ]}
        )

      # 1. On boot before any callback
      assert {:ok, initial_snapshot} = CapacityClaudeMonitor.current_snapshot(monitor)
      assert initial_snapshot.capacity_state == :unknown
      assert initial_snapshot.confidence == :none
      assert initial_snapshot.support_tier == :conservative_partial

      assert initial_snapshot.reason ==
               "rate_limits_absent_before_first_response_or_unsupported_subscription"

      assert initial_snapshot.windows == []
      refute CapacitySnapshot.eligible?(initial_snapshot, @official_eval_time)

      # 2. Receiving startup callback with rate_limits: nil
      missing_fixture = CapacityFixtures.load_fixture!("claude/missing-before-response.json")

      assert {:ok, :persisted, post_startup_snapshot} =
               CapacityClaudeMonitor.receive_status_line(monitor, missing_fixture)

      assert post_startup_snapshot.capacity_state == :unknown
      assert post_startup_snapshot.confidence == :none
      assert post_startup_snapshot.support_tier == :conservative_partial

      assert post_startup_snapshot.reason ==
               "rate_limits_absent_before_first_response_or_unsupported_subscription"

      # 3. Transitions to degraded/conservative_partial upon first response with rate limits
      normal_fixture = CapacityFixtures.load_fixture!("claude/normal-official-shape.json")

      assert {:ok, :persisted, response_snapshot} =
               CapacityClaudeMonitor.receive_status_line(monitor, normal_fixture)

      assert response_snapshot.capacity_state == :degraded
      assert response_snapshot.confidence == :medium
      assert response_snapshot.support_tier == :conservative_partial
      assert response_snapshot.reason == "conservative_partial_observation"
    end
  end

  describe "complete and partial windows" do
    test "normalizes complete windows into conservative-partial degraded snapshot", %{
      clock_fn: clock_fn
    } do
      monitor =
        start_supervised!(
          {CapacityClaudeMonitor,
           [
             name: nil,
             version: "2.1.251",
             clock: clock_fn,
             scope: "complete-session"
           ]}
        )

      fixture = CapacityFixtures.load_fixture!("claude/status-line-single-live.json")

      assert {:ok, :persisted, snapshot} =
               CapacityClaudeMonitor.receive_status_line(monitor, fixture)

      assert snapshot.capacity_state == :degraded
      assert snapshot.support_tier == :conservative_partial
      assert snapshot.compatibility_state == :compatible
      assert snapshot.confidence == :medium
      assert snapshot.reason == "conservative_partial_observation"

      [five_hour, seven_day] = snapshot.windows
      assert five_hour.kind == "five_hour"
      assert five_hour.state == :observed
      assert five_hour.used_percent == 25

      assert seven_day.kind == "seven_day"
      assert seven_day.state == :observed
      assert seven_day.used_percent == 94

      # Claude is never eligible for proactive automation admission
      refute CapacitySnapshot.eligible?(snapshot, @live_eval_time)
    end

    test "normalizes partial window into degraded snapshot without fabricating 0% usage", %{
      clock_agent: clock_agent,
      clock_fn: clock_fn
    } do
      TestClock.set(clock_agent, @official_eval_time)

      monitor =
        start_supervised!(
          {CapacityClaudeMonitor,
           [
             name: nil,
             version: "2.1.251",
             clock: clock_fn,
             scope: "partial-session"
           ]}
        )

      fixture = CapacityFixtures.load_fixture!("claude/partial-official-shape.json")

      assert {:ok, :persisted, snapshot} =
               CapacityClaudeMonitor.receive_status_line(monitor, fixture)

      assert snapshot.capacity_state == :degraded
      assert snapshot.support_tier == :conservative_partial
      assert snapshot.confidence == :medium
      assert snapshot.reason == "partial_window_observation"

      [five_hour, seven_day] = snapshot.windows
      assert five_hour.kind == "five_hour"
      assert five_hour.state == :observed
      assert five_hour.used_percent == 23.5

      # Missing window is unknown, never 0% or unlimited
      assert seven_day.kind == "seven_day"
      assert seven_day.state == :unknown
      refute Map.has_key?(seven_day, :used_percent)
    end
  end

  describe "version drift" do
    test "tested version 2.1.251 yields compatible outcome", %{clock_fn: clock_fn} do
      monitor =
        start_supervised!(
          {CapacityClaudeMonitor,
           [
             name: nil,
             version: "2.1.251",
             clock: clock_fn
           ]}
        )

      status = CapacityClaudeMonitor.status(monitor)
      assert status.compatibility.compatibility_state == :compatible
      assert status.compatibility.reason == nil
    end

    test "untested version 2.2.0 degrades compatibility state", %{
      clock_agent: clock_agent,
      clock_fn: clock_fn
    } do
      TestClock.set(clock_agent, @official_eval_time)

      monitor =
        start_supervised!(
          {CapacityClaudeMonitor,
           [
             name: nil,
             version: "2.2.0",
             clock: clock_fn
           ]}
        )

      status = CapacityClaudeMonitor.status(monitor)
      assert status.compatibility.compatibility_state == :degraded
      assert status.compatibility.reason == "untested_cli_version: 2.2.0"

      # Normalizing also carries the degraded compatibility
      fixture = CapacityFixtures.load_fixture!("claude/normal-official-shape.json")

      assert {:ok, :persisted, snapshot} =
               CapacityClaudeMonitor.receive_status_line(monitor, fixture)

      assert snapshot.compatibility_state == :degraded
    end
  end

  describe "concurrent sessions and scope isolation" do
    test "handles concurrent sessions from live fixture without conflating scopes", %{
      clock_agent: clock_agent,
      clock_fn: clock_fn
    } do
      TestClock.set(clock_agent, @concurrent_eval_time)

      monitor =
        start_supervised!(
          {CapacityClaudeMonitor,
           [
             name: nil,
             version: "2.1.251",
             clock: clock_fn
           ]}
        )

      fixture = CapacityFixtures.load_fixture!("claude/status-line-concurrent-live.json")

      # Observations contain interleaved callbacks from session_a and session_b
      [obs1, obs2, obs3, obs4] = fixture["observations"]

      # Both sessions send before-response callbacks
      assert {:ok, :persisted, _} =
               CapacityClaudeMonitor.receive_status_line(monitor, obs1,
                 scope: "session_a",
                 session_id: "session_a",
                 captured_at: obs1["observed_at"]
               )

      assert {:ok, :persisted, _} =
               CapacityClaudeMonitor.receive_status_line(monitor, obs2,
                 scope: "session_b",
                 session_id: "session_b",
                 captured_at: obs2["observed_at"]
               )

      # Session B receives usable response
      assert {:ok, :persisted, snap_b} =
               CapacityClaudeMonitor.receive_status_line(monitor, obs3,
                 scope: "session_b",
                 session_id: "session_b",
                 captured_at: obs3["observed_at"]
               )

      assert snap_b.scope == "session_b"
      assert snap_b.confidence == :medium

      # Session A receives usable response
      assert {:ok, :persisted, snap_a} =
               CapacityClaudeMonitor.receive_status_line(monitor, obs4,
                 scope: "session_a",
                 session_id: "session_a",
                 captured_at: obs4["observed_at"]
               )

      assert snap_a.scope == "session_a"
      assert snap_a.confidence == :medium

      # Confidence was not elevated beyond medium
      refute snap_a.confidence == :high
      refute snap_b.confidence == :high

      # Monitor tracks both active scopes independently
      status = CapacityClaudeMonitor.status(monitor)
      assert "session_a" in status.active_scopes
      assert "session_b" in status.active_scopes
    end

    test "keeps durable status and failure paths isolated by scope", %{clock_fn: clock_fn} do
      test_pid = self()
      {:ok, sink_mode} = Agent.start_link(fn -> :ok end)

      sink = fn snapshot, _opts ->
        send(test_pid, {:scope_sink_ingested, snapshot.scope, snapshot.snapshot_id})

        case Agent.get(sink_mode, & &1) do
          :ok -> {:ok, :persisted, snapshot}
          {:error, reason} -> {:error, reason}
        end
      end

      monitor =
        start_supervised!(
          {CapacityClaudeMonitor,
           [
             name: nil,
             version: "2.1.251",
             clock: clock_fn,
             sink: sink
           ]}
        )

      scope_a_payload = %{
        "captured_at" => "2026-08-29T07:34:18.000Z",
        "rate_limits" => %{
          "five_hour" => %{"used_percentage" => 11, "resets_at" => 1_787_994_000},
          "seven_day" => %{"used_percentage" => 22, "resets_at" => 1_788_033_600}
        }
      }

      scope_b_payload = %{
        "captured_at" => "2026-08-29T07:34:20.000Z",
        "rate_limits" => %{
          "five_hour" => %{"used_percentage" => 77, "resets_at" => 1_787_994_000},
          "seven_day" => %{"used_percentage" => 88, "resets_at" => 1_788_033_600}
        }
      }

      assert {:ok, :persisted, scope_a_snapshot} =
               CapacityClaudeMonitor.receive_status_line(monitor, scope_a_payload,
                 scope: "scope-a"
               )

      assert_receive {:scope_sink_ingested, "scope-a", scope_a_snapshot_id}
      assert scope_a_snapshot_id == scope_a_snapshot.snapshot_id

      assert {:error, :payload_oversized} =
               CapacityClaudeMonitor.receive_status_line(
                 monitor,
                 String.duplicate("a", 70_000),
                 scope: "scope-b"
               )

      refute_received {:scope_sink_ingested, "scope-b", _snapshot_id}

      assert {:ok, rejected_scope_b} =
               CapacityClaudeMonitor.current_snapshot(monitor, scope: "scope-b")

      assert rejected_scope_b.scope == "scope-b"
      assert rejected_scope_b.windows == []

      rejected_scope_b_status = CapacityClaudeMonitor.status(monitor, scope: "scope-b")
      assert rejected_scope_b_status.scope == "scope-b"
      assert rejected_scope_b_status.last_observation.windows == []
      assert rejected_scope_b_status.reason == "oversized_status_line_payload"

      scope_a_status_after_rejection = CapacityClaudeMonitor.status(monitor, scope: "scope-a")

      assert Enum.map(scope_a_status_after_rejection.last_observation.windows, & &1.used_percent) ==
               [11, 22]

      assert scope_a_status_after_rejection.reason == "conservative_partial_observation"

      assert {:ok, :persisted, scope_b_snapshot} =
               CapacityClaudeMonitor.receive_status_line(monitor, scope_b_payload,
                 scope: "scope-b"
               )

      assert_receive {:scope_sink_ingested, "scope-b", scope_b_snapshot_id}
      assert scope_b_snapshot_id == scope_b_snapshot.snapshot_id

      Agent.update(sink_mode, fn _ -> {:error, :scope_b_sink_down} end)

      changed_scope_b_payload =
        put_in(scope_b_payload, ["rate_limits", "five_hour", "used_percentage"], 99)
        |> Map.put("captured_at", "2026-08-29T07:34:21.000Z")

      assert {:error, {:sink_failure, :scope_b_sink_down}} =
               CapacityClaudeMonitor.receive_status_line(monitor, changed_scope_b_payload,
                 scope: "scope-b"
               )

      assert_receive {:scope_sink_ingested, "scope-b", _snapshot_id}

      assert {:ok, :deduplicated, duplicate_a} =
               CapacityClaudeMonitor.receive_status_line(monitor, scope_a_payload,
                 scope: "scope-a"
               )

      assert duplicate_a.scope == "scope-a"
      assert Enum.map(duplicate_a.windows, & &1.used_percent) == [11, 22]
      refute_received {:scope_sink_ingested, "scope-a", _snapshot_id}

      assert {:ok, :deduplicated, duplicate_b} =
               CapacityClaudeMonitor.receive_status_line(monitor, scope_b_payload,
                 scope: "scope-b"
               )

      assert duplicate_b.scope == "scope-b"
      assert Enum.map(duplicate_b.windows, & &1.used_percent) == [77, 88]
      refute_received {:scope_sink_ingested, "scope-b", _snapshot_id}

      assert {:ok, disconnected_a} =
               CapacityClaudeMonitor.disconnect(monitor, "scope_a_closed", scope: "scope-a")

      assert disconnected_a.scope == "scope-a"
      assert Enum.map(disconnected_a.windows, & &1.used_percent) == [11, 22]

      assert {:ok, current_a} =
               CapacityClaudeMonitor.current_snapshot(monitor, scope: "scope-a")

      assert {:ok, current_b} =
               CapacityClaudeMonitor.current_snapshot(monitor, scope: "scope-b")

      assert current_a.scope == "scope-a"
      assert Enum.map(current_a.windows, & &1.used_percent) == [11, 22]
      assert current_b.scope == "scope-b"
      assert Enum.map(current_b.windows, & &1.used_percent) == [77, 88]

      status_a = CapacityClaudeMonitor.status(monitor, scope: "scope-a")
      status_b = CapacityClaudeMonitor.status(monitor, scope: "scope-b")

      assert status_a.scope == "scope-a"
      assert status_a.status == :disconnected
      assert status_a.sink_status == :ok
      refute status_a.reason =~ "sink_failure"
      assert Enum.map(status_a.last_observation.windows, & &1.used_percent) == [11, 22]
      assert status_b.scope == "scope-b"
      assert status_b.sink_status == {:error, :scope_b_sink_down}
      assert status_b.reason =~ "sink_failure"
      assert Enum.map(status_b.last_observation.windows, & &1.used_percent) == [77, 88]
    end

    test "concurrent session divergence degrades confidence to low", %{clock_fn: clock_fn} do
      monitor =
        start_supervised!(
          {CapacityClaudeMonitor,
           [
             name: nil,
             version: "2.1.251",
             clock: clock_fn,
             scope: "shared-subscription"
           ]}
        )

      # Session 1 reports 25%
      payload1 = %{
        "captured_at" => "2026-08-29T07:34:19.000Z",
        "rate_limits" => %{
          "five_hour" => %{"used_percentage" => 25, "resets_at" => 1_787_994_000},
          "seven_day" => %{"used_percentage" => 94, "resets_at" => 1_788_033_600}
        }
      }

      assert {:ok, :persisted, _} =
               CapacityClaudeMonitor.receive_status_line(monitor, payload1,
                 session_id: "session_1",
                 captured_at: ~U[2026-08-29 07:34:19Z]
               )

      # Concurrent Session 2 reports divergent 35% within the same scope
      payload2 = %{
        "captured_at" => "2026-08-29T07:34:20.000Z",
        "rate_limits" => %{
          "five_hour" => %{"used_percentage" => 35, "resets_at" => 1_787_994_000},
          "seven_day" => %{"used_percentage" => 94, "resets_at" => 1_788_033_600}
        }
      }

      assert {:ok, :persisted, divergent_snap} =
               CapacityClaudeMonitor.receive_status_line(monitor, payload2,
                 session_id: "session_2",
                 captured_at: ~U[2026-08-29 07:34:20Z]
               )

      # Divergence causes conservative degradation to low confidence
      assert divergent_snap.confidence == :low
      assert divergent_snap.capacity_state == :degraded
      assert divergent_snap.reason =~ "concurrent_session_divergence"
    end
  end

  describe "duplicate and out-of-order callback determinism" do
    test "duplicate callback returns :deduplicated and does not alter state", %{
      clock_fn: clock_fn
    } do
      monitor =
        start_supervised!(
          {CapacityClaudeMonitor,
           [
             name: nil,
             version: "2.1.251",
             clock: clock_fn
           ]}
        )

      fixture = CapacityFixtures.load_fixture!("claude/status-line-single-live.json")

      assert {:ok, :persisted, first_snap} =
               CapacityClaudeMonitor.receive_status_line(monitor, fixture)

      # Sending identical callback again
      assert {:ok, :deduplicated, dup_snap} =
               CapacityClaudeMonitor.receive_status_line(monitor, fixture)

      assert dup_snap.snapshot_id == first_snap.snapshot_id
      assert dup_snap.observed_at == first_snap.observed_at
    end

    test "out-of-order callback does not regress newer observation", %{clock_fn: clock_fn} do
      monitor =
        start_supervised!(
          {CapacityClaudeMonitor,
           [
             name: nil,
             version: "2.1.251",
             clock: clock_fn
           ]}
        )

      newer_payload = %{
        "captured_at" => "2026-08-29T07:34:20.000Z",
        "rate_limits" => %{
          "five_hour" => %{"used_percentage" => 30, "resets_at" => 1_787_994_000},
          "seven_day" => %{"used_percentage" => 90, "resets_at" => 1_788_033_600}
        }
      }

      assert {:ok, :persisted, newer_snap} =
               CapacityClaudeMonitor.receive_status_line(monitor, newer_payload,
                 captured_at: ~U[2026-08-29 07:34:20Z]
               )

      # Older callback arrives later
      older_payload = %{
        "captured_at" => "2026-08-29T07:34:10.000Z",
        "rate_limits" => %{
          "five_hour" => %{"used_percentage" => 20, "resets_at" => 1_787_994_000},
          "seven_day" => %{"used_percentage" => 80, "resets_at" => 1_788_033_600}
        }
      }

      assert {:ok, :out_of_order, preserved_snap} =
               CapacityClaudeMonitor.receive_status_line(monitor, older_payload,
                 captured_at: ~U[2026-08-29 07:34:10Z]
               )

      # Preserves newer 30% observation
      assert preserved_snap.snapshot_id == newer_snap.snapshot_id
      [w5, _] = preserved_snap.windows
      assert w5.used_percent == 30
    end
  end

  describe "quota refusal and error handling" do
    test "quota refusal produces refused snapshot and transitions status to :refused", %{
      clock_fn: clock_fn
    } do
      monitor =
        start_supervised!(
          {CapacityClaudeMonitor,
           [
             name: nil,
             version: "2.1.251",
             clock: clock_fn
           ]}
        )

      fixture = CapacityFixtures.load_fixture!("claude/refusal-unverified.json")

      assert {:ok, :persisted, snapshot} =
               CapacityClaudeMonitor.receive_status_line(monitor, fixture)

      assert snapshot.capacity_state == :refused
      assert snapshot.confidence == :low
      assert snapshot.reason == "cli_reported_rate_limit_refusal_without_capacity_snapshot"
      assert snapshot.source.event == :status_line_input

      status = CapacityClaudeMonitor.status(monitor)
      assert status.status == :refused
    end

    test "malformed payload preserves last-known observation", %{clock_fn: clock_fn} do
      monitor =
        start_supervised!(
          {CapacityClaudeMonitor,
           [
             name: nil,
             version: "2.1.251",
             clock: clock_fn
           ]}
        )

      valid_fixture = CapacityFixtures.load_fixture!("claude/status-line-single-live.json")

      assert {:ok, :persisted, _} =
               CapacityClaudeMonitor.receive_status_line(monitor, valid_fixture)

      # Now send malformed replay fixture
      malformed_fixture = CapacityFixtures.load_fixture!("claude/malformed-replay.json")

      assert {:error, _reason} =
               CapacityClaudeMonitor.receive_status_line(monitor, malformed_fixture)

      # Last known observation is preserved in degraded state without 0% usage
      status = CapacityClaudeMonitor.status(monitor)
      assert status.status == :degraded
      assert status.last_observation.capacity_state == :degraded
      [five_hour, seven_day] = status.last_observation.windows
      assert five_hour.used_percent == 25
      assert seven_day.used_percent == 94
    end

    test "oversized payload is rejected and preserves last-known observation", %{
      clock_fn: clock_fn
    } do
      test_pid = self()

      sink = fn snapshot, _opts ->
        send(test_pid, {:oversized_test_sink_ingested, snapshot.snapshot_id})
        {:ok, :persisted, snapshot}
      end

      monitor =
        start_supervised!(
          {CapacityClaudeMonitor,
           [
             name: nil,
             version: "2.1.251",
             clock: clock_fn,
             sink: sink
           ]}
        )

      valid_fixture = CapacityFixtures.load_fixture!("claude/status-line-single-live.json")

      assert {:ok, :persisted, valid_snapshot} =
               CapacityClaudeMonitor.receive_status_line(monitor, valid_fixture)

      assert_receive {:oversized_test_sink_ingested, valid_snapshot_id}
      assert valid_snapshot_id == valid_snapshot.snapshot_id

      oversized = String.duplicate("a", 70_000)

      assert {:error, :payload_oversized} =
               CapacityClaudeMonitor.receive_status_line(monitor, oversized)

      refute_received {:oversized_test_sink_ingested, _snapshot_id}

      status = CapacityClaudeMonitor.status(monitor)
      assert status.status == :degraded
      assert status.reason =~ "oversized_status_line_payload"
      assert status.last_observation.capacity_state == :degraded
    end
  end

  describe "timestamps, freshness, and future timestamps" do
    test "future timestamp preserves last-known observation", %{clock_fn: clock_fn} do
      monitor =
        start_supervised!(
          {CapacityClaudeMonitor,
           [
             name: nil,
             version: "2.1.251",
             clock: clock_fn
           ]}
        )

      valid_fixture = CapacityFixtures.load_fixture!("claude/status-line-single-live.json")

      assert {:ok, :persisted, last_known} =
               CapacityClaudeMonitor.receive_status_line(monitor, valid_fixture)

      assert Enum.map(last_known.windows, & &1.used_percent) == [25, 94]

      future_payload = %{
        "captured_at" => "2026-08-29T07:40:00.000Z",
        "rate_limits" => %{
          "five_hour" => %{"used_percentage" => 20, "resets_at" => 1_787_994_000}
        }
      }

      assert {:ok, :persisted, snapshot} =
               CapacityClaudeMonitor.receive_status_line(monitor, future_payload,
                 captured_at: ~U[2026-08-29 07:40:00Z]
               )

      assert snapshot.capacity_state == :degraded
      assert snapshot.confidence == :low
      assert snapshot.reason =~ "missing_or_invalid_observation_timestamp"
      assert Enum.map(snapshot.windows, & &1.used_percent) == [25, 94]

      assert {:ok, current} = CapacityClaudeMonitor.current_snapshot(monitor)
      assert Enum.map(current.windows, & &1.used_percent) == [25, 94]
    end

    test "future timestamp without last-known observation stays unknown", %{clock_fn: clock_fn} do
      monitor =
        start_supervised!(
          {CapacityClaudeMonitor,
           [
             name: nil,
             version: "2.1.251",
             clock: clock_fn
           ]}
        )

      future_payload = %{
        "captured_at" => "2026-08-29T07:40:00.000Z",
        "rate_limits" => %{
          "five_hour" => %{"used_percentage" => 20, "resets_at" => 1_787_994_000}
        }
      }

      assert {:ok, :persisted, snapshot} =
               CapacityClaudeMonitor.receive_status_line(monitor, future_payload,
                 captured_at: ~U[2026-08-29 07:40:00Z],
                 scope: "future-empty"
               )

      assert snapshot.scope == "future-empty"
      assert snapshot.capacity_state == :unknown
      assert snapshot.confidence == :none
      assert snapshot.reason == "missing_or_invalid_observation_timestamp"
      refute Enum.any?(snapshot.windows, &(&1.state == :observed))
    end

    test "stale observation degrades gracefully with low confidence", %{
      clock_agent: clock_agent,
      clock_fn: clock_fn
    } do
      monitor =
        start_supervised!(
          {CapacityClaudeMonitor,
           [
             name: nil,
             version: "2.1.251",
             clock: clock_fn
           ]}
        )

      fixture = CapacityFixtures.load_fixture!("claude/stale-replay.json")

      # Evaluated when time has advanced past 300s relative to captured_at (03:30:00)
      TestClock.set(clock_agent, ~U[2026-08-29 04:30:00Z])

      receive_result =
        CapacityClaudeMonitor.receive_status_line(monitor, fixture,
          captured_at: ~U[2026-08-29 03:30:00Z]
        )

      assert {:ok, _status, snapshot} = receive_result
      assert snapshot.capacity_state == :degraded
      assert snapshot.confidence == :low
      assert snapshot.reason == "stale_observation"

      status = CapacityClaudeMonitor.status(monitor)
      assert status.status == :stale
    end
  end

  describe "sink failure and recovery" do
    test "degrades safely when sink fails and recovers when sink succeeds", %{clock_fn: clock_fn} do
      {:ok, sink_fail_flag} = Agent.start_link(fn -> true end)

      mock_sink = fn snapshot, _opts ->
        if Agent.get(sink_fail_flag, & &1) do
          {:error, :database_unreachable}
        else
          {:ok, :persisted, snapshot}
        end
      end

      monitor =
        start_supervised!(
          {CapacityClaudeMonitor,
           [
             name: nil,
             version: "2.1.251",
             clock: clock_fn,
             sink: mock_sink
           ]}
        )

      fixture = CapacityFixtures.load_fixture!("claude/status-line-single-live.json")

      # 1. Sink fails
      assert {:error, {:sink_failure, :database_unreachable}} =
               CapacityClaudeMonitor.receive_status_line(monitor, fixture)

      status = CapacityClaudeMonitor.status(monitor)
      assert status.status == :degraded
      assert status.sink_status == {:error, :database_unreachable}
      assert status.reason =~ "sink_failure"

      # 2. Sink recovers
      Agent.update(sink_fail_flag, fn _ -> false end)

      assert {:ok, :persisted, snapshot} =
               CapacityClaudeMonitor.receive_status_line(monitor, fixture)

      assert snapshot.capacity_state == :degraded
      recovered_status = CapacityClaudeMonitor.status(monitor)
      assert recovered_status.sink_status == :ok
    end

    test "treats a crashing sink task as a sink failure without crashing the monitor", %{
      clock_fn: clock_fn
    } do
      crashing_sink = fn _snapshot, _opts -> Process.exit(self(), :kill) end

      monitor =
        start_supervised!(
          {CapacityClaudeMonitor,
           [
             name: nil,
             version: "2.1.251",
             clock: clock_fn,
             sink: crashing_sink
           ]}
        )

      fixture = CapacityFixtures.load_fixture!("claude/status-line-single-live.json")

      assert {:error, {:sink_failure, :killed}} =
               CapacityClaudeMonitor.receive_status_line(monitor, fixture)

      status = CapacityClaudeMonitor.status(monitor)
      assert status.status == :degraded
      assert status.sink_status == {:error, :killed}
      assert status.reason =~ "sink_failure"
    end
  end

  describe "security, secret scanning, and disconnect" do
    test "rejects callback containing secret token and redacts", %{clock_fn: clock_fn} do
      test_pid = self()

      sink = fn snapshot, _opts ->
        send(test_pid, {:secret_test_sink_ingested, snapshot.snapshot_id})
        {:ok, :persisted, snapshot}
      end

      monitor =
        start_supervised!(
          {CapacityClaudeMonitor,
           [
             name: nil,
             version: "2.1.251",
             clock: clock_fn,
             sink: sink
           ]}
        )

      secret_payload = %{
        "api_key" => "sk-ant-api03-abcdef1234567890",
        "rate_limits" => %{"five_hour" => %{"used_percentage" => 20}}
      }

      assert {:error, :contains_secrets_or_forbidden_content} =
               CapacityClaudeMonitor.receive_status_line(monitor, secret_payload)

      refute_received {:secret_test_sink_ingested, _snapshot_id}

      status = CapacityClaudeMonitor.status(monitor)
      refute status.reason =~ "sk-ant"
      refute status.reason =~ "abcdef"
    end

    test "disconnect/2 preserves last known observation in degraded state", %{clock_fn: clock_fn} do
      monitor =
        start_supervised!(
          {CapacityClaudeMonitor,
           [
             name: nil,
             version: "2.1.251",
             clock: clock_fn
           ]}
        )

      fixture = CapacityFixtures.load_fixture!("claude/status-line-single-live.json")
      assert {:ok, :persisted, _} = CapacityClaudeMonitor.receive_status_line(monitor, fixture)

      assert {:ok, disconnected_snap} =
               CapacityClaudeMonitor.disconnect(monitor, "user_exited_terminal")

      assert disconnected_snap.capacity_state == :degraded
      assert disconnected_snap.confidence == :low
      assert disconnected_snap.reason =~ "session_disconnected: user_exited_terminal"

      status = CapacityClaudeMonitor.status(monitor)
      assert status.status == :disconnected
    end

    test "redacts secrets from stored disconnect reasons", %{clock_fn: clock_fn} do
      monitor =
        start_supervised!(
          {CapacityClaudeMonitor,
           [
             name: nil,
             version: "2.1.251",
             clock: clock_fn
           ]}
        )

      secret_reason = "api_key=sk-ant-api03-abcdef1234567890"

      assert {:ok, snapshot} = CapacityClaudeMonitor.disconnect(monitor, secret_reason)
      assert snapshot.reason =~ "[REDACTED]"
      refute snapshot.reason =~ "sk-ant"
      refute snapshot.reason =~ "abcdef"

      status = CapacityClaudeMonitor.status(monitor)
      assert status.reason =~ "[REDACTED]"
      refute status.reason =~ "sk-ant"
      refute status.reason =~ "abcdef"
    end

    test "reset/1 restores pre-first-response initial state", %{clock_fn: clock_fn} do
      monitor =
        start_supervised!(
          {CapacityClaudeMonitor,
           [
             name: nil,
             version: "2.1.251",
             clock: clock_fn
           ]}
        )

      fixture = CapacityFixtures.load_fixture!("claude/status-line-single-live.json")
      assert {:ok, :persisted, _} = CapacityClaudeMonitor.receive_status_line(monitor, fixture)
      assert %{status: :degraded} = CapacityClaudeMonitor.status(monitor)

      assert :ok = CapacityClaudeMonitor.reset(monitor)
      status = CapacityClaudeMonitor.status(monitor)
      assert status.status == :ready
      assert status.last_observation.capacity_state == :unknown

      assert status.last_observation.reason ==
               "rate_limits_absent_before_first_response_or_unsupported_subscription"
    end
  end

  describe "convenience module Shoestring.Harness.ClaudeMonitor" do
    test "delegates transparently to Capacity.ClaudeMonitor", %{clock_fn: clock_fn} do
      # Test named process start with default name
      _ =
        start_supervised!(
          {ClaudeMonitor,
           [
             version: "2.1.251",
             clock: clock_fn
           ]}
        )

      assert {:ok, snapshot} = ClaudeMonitor.current_snapshot()
      assert snapshot.capacity_state == :unknown

      assert %{status: :ready} = ClaudeMonitor.status()
      assert %{provider_id: "claude"} = ClaudeMonitor.provenance()
      assert ClaudeMonitor.support_tier() == :conservative_partial

      # observe/1 implementation
      assert {:ok, obs_snap} = ClaudeMonitor.observe()
      assert obs_snap.capacity_state == :unknown
    end
  end
end
