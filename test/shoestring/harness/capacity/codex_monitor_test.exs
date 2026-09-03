defmodule Shoestring.Harness.Capacity.CodexMonitorTest do
  use ExUnit.Case, async: false

  alias Shoestring.Harness.Capacity.CodexMonitor
  alias Shoestring.Harness.CodexMonitor, as: HarnessCodexMonitor
  alias Shoestring.Harness.CapacitySnapshot
  alias Shoestring.Harness.Capacity.Fixtures
  alias Shoestring.Harness.Capacity.Codex.FakeTransport

  @eval_time ~U[2026-08-29 04:38:25Z]

  setup do
    # Load Gate 0A fixtures
    normal_fixture = Fixtures.load_fixture!("codex/normal-read.json")
    sparse_fixture = Fixtures.load_fixture!("codex/sparse-update-live.json")
    refusal_fixture = Fixtures.load_fixture!("codex/refusal-unverified.json")

    {:ok,
     normal_read: normal_fixture["payload"]["result"],
     sparse_update: sparse_fixture["payload"]["params"],
     refusal_result: refusal_fixture["payload"]["result"]}
  end

  defp default_auto_respond(normal_read) do
    fn
      %{"method" => "initialize", "id" => id} ->
        %{
          "id" => id,
          "result" => %{
            "platformFamily" => "unix",
            "platformOs" => "macos",
            "codexHome" => "/secret/path/should/be/discarded"
          }
        }

      %{"method" => "account/read", "id" => id} ->
        %{
          "id" => id,
          "result" => %{
            "account" => %{
              "type" => "chatgpt",
              "planType" => "plus"
            },
            "requiresOpenaiAuth" => true
          }
        }

      %{"method" => "account/rateLimits/read", "id" => id} ->
        %{
          "id" => id,
          "result" => normal_read
        }

      _ ->
        nil
    end
  end

  defp sync_handshake(monitor, fake_transport, rounds \\ 5) do
    Enum.each(1..rounds, fn _ ->
      if fake_transport && Process.alive?(fake_transport), do: _ = :sys.get_state(fake_transport)
      if monitor && Process.alive?(monitor), do: _ = :sys.get_state(monitor)
    end)
  end

  describe "handshake, explicit read, and update notifications" do
    test "completes evidenced initialize/account handshake and ingests rate limits",
         %{normal_read: normal_read} do
      test_pid = self()

      sink = fn snapshot ->
        send(test_pid, {:ingested, snapshot})
        {:ok, :persisted, snapshot}
      end

      {:ok, fake_transport} =
        start_supervised(
          {FakeTransport,
           owner: self(), emit_connected: false, auto_respond: default_auto_respond(normal_read)}
        )

      monitor =
        start_supervised!(
          {CodexMonitor,
           name: false,
           version: "0.150.1",
           transport_pid: fake_transport,
           sink: sink,
           clock: fn -> @eval_time end,
           base_backoff_ms: 50,
           max_backoff_ms: 100}
        )

      # Ensure fake transport delivers to monitor
      _ = :sys.get_state(monitor)

      # Wait for ingestion from handshake
      assert_receive {:ingested, %CapacitySnapshot{} = snapshot}
      assert snapshot.capacity_state == :observed
      assert snapshot.support_tier == :proactive
      assert snapshot.compatibility_state == :compatible
      assert snapshot.confidence == :high

      [primary, secondary] = snapshot.windows
      assert primary.kind == "primary"
      assert primary.used_percent == 13
      assert secondary.kind == "secondary"
      assert secondary.used_percent == 16

      # Check monitor state
      assert CodexMonitor.status(monitor) == :connected
      status_map = CodexMonitor.get_status(monitor)
      assert status_map.status == :connected
      assert status_map.connected? == true
      assert status_map.account_info.plan_type == "plus"

      # Verify sent frames during handshake
      sent = FakeTransport.get_sent_frames(fake_transport)
      methods = Enum.map(sent, &Map.get(&1, "method"))
      assert "initialize" in methods
      assert "initialized" in methods
      assert "account/read" in methods
      assert "account/rateLimits/read" in methods

      # Verify initialize parameters adhered to evidenced clientInfo
      init_frame = Enum.find(sent, &(&1["method"] == "initialize"))
      assert get_in(init_frame, ["params", "clientInfo", "name"]) == "shoestring_codex_monitor"
    end

    test "consumes account/rateLimits/updated notifications",
         %{normal_read: normal_read, sparse_update: sparse_update} do
      test_pid = self()

      sink = fn snapshot ->
        send(test_pid, {:ingested, snapshot})
        {:ok, :persisted, snapshot}
      end

      {:ok, fake_transport} =
        start_supervised(
          {FakeTransport,
           owner: self(), emit_connected: false, auto_respond: default_auto_respond(normal_read)}
        )

      monitor =
        start_supervised!(
          {CodexMonitor,
           name: false,
           version: "0.150.1",
           transport_pid: fake_transport,
           sink: sink,
           clock: fn -> @eval_time end}
        )

      _ = :sys.get_state(monitor)
      assert_receive {:ingested, _initial}

      # Push rate limits update notification with modified primary percentage
      updated_sparse =
        put_in(sparse_update, ["rateLimits", "primary", "usedPercent"], 25)

      FakeTransport.push_notification(
        fake_transport,
        "account/rateLimits/updated",
        updated_sparse
      )

      _ = :sys.get_state(monitor)

      assert_receive {:ingested, %CapacitySnapshot{} = updated_snapshot}
      assert updated_snapshot.source.event == :update_notification
      [primary, secondary] = updated_snapshot.windows
      assert primary.used_percent == 25
      # Secondary was retained
      assert secondary.used_percent == 16
    end
  end

  describe "sparse merge semantics" do
    test "merges sparse update without erasing omitted secondary window",
         %{normal_read: normal_read} do
      test_pid = self()

      sink = fn snapshot ->
        send(test_pid, {:ingested, snapshot})
        {:ok, :persisted, snapshot}
      end

      {:ok, fake_transport} =
        start_supervised(
          {FakeTransport,
           owner: self(), emit_connected: false, auto_respond: default_auto_respond(normal_read)}
        )

      monitor =
        start_supervised!(
          {CodexMonitor,
           name: false,
           version: "0.150.1",
           transport_pid: fake_transport,
           sink: sink,
           clock: fn -> @eval_time end}
        )

      _ = :sys.get_state(monitor)
      assert_receive {:ingested, initial}
      assert length(initial.windows) == 2

      # Push an extremely sparse update that omits secondary entirely
      sparse_payload = %{
        "rateLimits" => %{
          "primary" => %{
            "usedPercent" => 35,
            "windowDurationMins" => 300,
            "resetsAt" => 1_787_994_541
          }
        }
      }

      FakeTransport.push_notification(
        fake_transport,
        "account/rateLimits/updated",
        sparse_payload
      )

      _ = :sys.get_state(monitor)

      assert_receive {:ingested, updated}
      assert updated.capacity_state == :observed
      [primary, secondary] = updated.windows
      assert primary.used_percent == 35
      assert secondary.kind == "secondary"
      assert secondary.used_percent == 16
      assert secondary.state == :observed
    end

    test "direct merge_provider_state preserves metadata when absent in update",
         %{normal_read: normal_read} do
      last_known = %{
        "result" => normal_read
      }

      sparse_update = %{
        "rateLimits" => %{
          "primary" => %{
            "usedPercent" => 42
          }
        }
      }

      merged = CodexMonitor.merge_provider_state(last_known, sparse_update)
      result = merged["result"]
      rate_limits = result["rateLimits"]

      assert rate_limits["primary"]["usedPercent"] == 42
      assert rate_limits["primary"]["windowDurationMins"] == 300
      assert rate_limits["secondary"]["usedPercent"] == 16
      assert rate_limits["planType"] == "plus"
      assert rate_limits["spendControlReached"] == false
      assert result["rateLimitResetCredits"]["availableCount"] == 1
    end
  end

  describe "interleaving, duplicate, and out-of-order frames" do
    test "tolerates interleaved notifications while a request is pending",
         %{normal_read: normal_read, sparse_update: sparse_update} do
      test_pid = self()

      sink = fn snapshot ->
        send(test_pid, {:ingested, snapshot})
        {:ok, :persisted, snapshot}
      end

      # In auto_respond, delay answering rateLimits/read to allow testing interleaving
      auto_respond = fn
        %{"method" => "initialize", "id" => id} ->
          %{"id" => id, "result" => %{"platformFamily" => "unix"}}

        %{"method" => "account/read", "id" => id} ->
          %{"id" => id, "result" => %{"account" => %{"type" => "chatgpt", "planType" => "plus"}}}

        %{"method" => "account/rateLimits/read"} ->
          # Do not auto respond immediately
          :ignore

        _ ->
          nil
      end

      {:ok, fake_transport} =
        start_supervised(
          {FakeTransport, owner: self(), emit_connected: false, auto_respond: auto_respond}
        )

      monitor =
        start_supervised!(
          {CodexMonitor,
           name: false,
           version: "0.150.1",
           transport_pid: fake_transport,
           sink: sink,
           clock: fn -> @eval_time end}
        )

      _ = :sys.get_state(monitor)

      # While account/rateLimits/read (id 3) is pending, push an interleaved notification
      FakeTransport.push_notification(
        fake_transport,
        "account/rateLimits/updated",
        sparse_update
      )

      _ = :sys.get_state(monitor)
      # Notification processed
      assert_receive {:ingested, _notif_snapshot}

      # Now provide the response to the pending request (id: 3)
      FakeTransport.push_frame(fake_transport, %{
        "id" => "0:3",
        "result" => normal_read
      })

      _ = :sys.get_state(monitor)
      assert_receive {:ingested, _read_snapshot}

      assert CodexMonitor.status(monitor) == :connected
    end

    test "safely ignores duplicate and uncorrelated response frames without crashing",
         %{normal_read: normal_read} do
      {:ok, fake_transport} =
        start_supervised(
          {FakeTransport,
           owner: self(), emit_connected: false, auto_respond: default_auto_respond(normal_read)}
        )

      monitor =
        start_supervised!(
          {CodexMonitor,
           name: false,
           version: "0.150.1",
           transport_pid: fake_transport,
           sink: fn s -> {:ok, :persisted, s} end,
           clock: fn -> ~U[2026-08-29 04:38:25Z] end}
        )

      sync_handshake(monitor, fake_transport)
      assert CodexMonitor.status(monitor) == :connected

      # Send a duplicate response for id 3
      FakeTransport.push_frame(fake_transport, %{"id" => "0:3", "result" => normal_read})
      _ = :sys.get_state(monitor)
      assert CodexMonitor.status(monitor) == :connected

      # Send an uncorrelated response id
      FakeTransport.push_frame(fake_transport, %{"id" => "0:9999", "result" => %{}})
      _ = :sys.get_state(monitor)
      assert CodexMonitor.status(monitor) == :connected

      # Send a bare integer id (safely dropped under new epoch scheme since it doesn't start with "0:")
      FakeTransport.push_frame(fake_transport, %{"id" => 3, "result" => normal_read})
      _ = :sys.get_state(monitor)
      assert CodexMonitor.status(monitor) == :connected
    end

    test "stale transport is closed and delayed reply from prior epoch is ignored" do
      # 1. Provide an injected transport_mod, not configured_transport_pid
      monitor =
        start_supervised!(
          {CodexMonitor,
           name: false,
           version: "0.150.1",
           transport: FakeTransport,
           transport_opts: [owner: self(), emit_connected: true, auto_respond: nil],
           base_backoff_ms: 100_000,
           max_backoff_ms: 100_000,
           clock: fn -> ~U[2026-08-29 04:38:25Z] end}
        )

      _ = :sys.get_state(monitor)
      status1 = CodexMonitor.get_status(monitor)
      transport1 = status1.transport_pid
      assert is_pid(transport1)
      assert Process.alive?(transport1)

      # 2. Simulate error
      send(monitor, {:codex_transport_error, transport1, :oversized_frame})
      _ = :sys.get_state(monitor)

      # Assert the old transport was closed
      assert Process.alive?(transport1) == false

      # 3. Force reconnect
      CodexMonitor.reconnect(monitor)
      _ = :sys.get_state(monitor)

      status2 = CodexMonitor.get_status(monitor)
      transport2 = status2.transport_pid
      assert is_pid(transport2)
      assert transport2 != transport1

      # 4. Push a frame with OLD epoch ID. Generation was 0, now it's 1.
      # If we send a response with id "0:1", it should be ignored.
      FakeTransport.push_frame(transport2, %{"id" => "0:1", "result" => %{}})
      _ = :sys.get_state(monitor)

      assert CodexMonitor.status(monitor) == :unavailable

      # Ensure there are no pending requests leaked or crashed
      status_final = CodexMonitor.get_status(monitor)
      # The handshake initialize from attempt 2
      assert status_final.pending_request_count == 1
    end
  end

  describe "version drift and compatibility" do
    test "tested version 0.150.1 enters :connected state", %{normal_read: normal_read} do
      {:ok, fake_transport} =
        start_supervised(
          {FakeTransport,
           owner: self(), emit_connected: false, auto_respond: default_auto_respond(normal_read)}
        )

      monitor =
        start_supervised!(
          {CodexMonitor,
           name: false,
           version: "0.150.1",
           transport_pid: fake_transport,
           sink: fn s -> {:ok, :persisted, s} end,
           clock: fn -> @eval_time end}
        )

      sync_handshake(monitor, fake_transport)
      assert CodexMonitor.status(monitor) == :connected
    end

    test "untested version drift 0.151.0 connects but remains :degraded",
         %{normal_read: normal_read} do
      {:ok, fake_transport} =
        start_supervised(
          {FakeTransport,
           owner: self(), emit_connected: false, auto_respond: default_auto_respond(normal_read)}
        )

      monitor =
        start_supervised!(
          {CodexMonitor,
           name: false,
           version: "0.151.0",
           transport_pid: fake_transport,
           sink: fn s -> {:ok, :persisted, s} end,
           clock: fn -> @eval_time end}
        )

      sync_handshake(monitor, fake_transport)
      assert CodexMonitor.status(monitor) == :incompatible_schema
      status_map = CodexMonitor.get_status(monitor)
      assert status_map.status == :incompatible_schema
      assert status_map.connected? == true
      assert status_map.compatibility.compatibility_state == :degraded
    end

    test "missing executable halts in :incompatible state without connecting" do
      runner = fn _cmd, _args -> {"not found", 127} end

      monitor =
        start_supervised!(
          {CodexMonitor, name: false, runner: runner, sink: fn s -> {:ok, :persisted, s} end}
        )

      _ = :sys.get_state(monitor)
      assert CodexMonitor.status(monitor) == :incompatible
      assert CodexMonitor.get_status(monitor).connected? == false
    end
  end

  describe "authentication required and quota refusal" do
    test "transitions to :auth_required when account/read requires authentication" do
      auto_respond = fn
        %{"method" => "initialize", "id" => id} ->
          %{"id" => id, "result" => %{"platformFamily" => "unix"}}

        %{"method" => "account/read", "id" => id} ->
          # Unauthenticated state
          %{
            "id" => id,
            "result" => %{
              "account" => nil,
              "requiresOpenaiAuth" => true
            }
          }

        _ ->
          nil
      end

      {:ok, fake_transport} =
        start_supervised(
          {FakeTransport, owner: self(), emit_connected: false, auto_respond: auto_respond}
        )

      monitor =
        start_supervised!(
          {CodexMonitor,
           name: false,
           version: "0.150.1",
           transport_pid: fake_transport,
           sink: fn s -> {:ok, :persisted, s} end}
        )

      sync_handshake(monitor, fake_transport)
      assert CodexMonitor.status(monitor) == :auth_required
      assert CodexMonitor.get_status(monitor).connected? == false

      # Verify rateLimits/read was never called
      sent = FakeTransport.get_sent_frames(fake_transport)
      refute Enum.any?(sent, &(&1["method"] == "account/rateLimits/read"))
    end

    test "structured quota refusal sets status to :degraded and snapshot to :refused",
         %{refusal_result: refusal_result} do
      test_pid = self()

      sink = fn snapshot ->
        send(test_pid, {:ingested, snapshot})
        {:ok, :persisted, snapshot}
      end

      auto_respond = fn
        %{"method" => "initialize", "id" => id} ->
          %{"id" => id, "result" => %{"platformFamily" => "unix"}}

        %{"method" => "account/read", "id" => id} ->
          %{"id" => id, "result" => %{"account" => %{"type" => "chatgpt", "planType" => "plus"}}}

        %{"method" => "account/rateLimits/read", "id" => id} ->
          %{"id" => id, "result" => refusal_result}

        _ ->
          nil
      end

      {:ok, fake_transport} =
        start_supervised(
          {FakeTransport, owner: self(), emit_connected: false, auto_respond: auto_respond}
        )

      monitor =
        start_supervised!(
          {CodexMonitor,
           name: false,
           version: "0.150.1",
           transport_pid: fake_transport,
           sink: sink,
           clock: fn -> @eval_time end}
        )

      _ = :sys.get_state(monitor)
      assert_receive {:ingested, snapshot}

      assert snapshot.capacity_state == :refused
      assert snapshot.confidence == :low
      assert snapshot.extensions["codex:rate_limit_reached_type"] == "rate_limit_reached"

      # Monitor classifies fail-closed as :degraded
      assert CodexMonitor.status(monitor) == :refused
    end
  end

  describe "disconnect, backoff cap, and last-known preservation" do
    test "preserves last-known observation with degraded state upon disconnect",
         %{normal_read: normal_read} do
      test_pid = self()

      sink = fn snapshot ->
        send(test_pid, {:ingested, snapshot})
        {:ok, :persisted, snapshot}
      end

      {:ok, fake_transport} =
        start_supervised(
          {FakeTransport,
           owner: self(), emit_connected: false, auto_respond: default_auto_respond(normal_read)}
        )

      monitor =
        start_supervised!(
          {CodexMonitor,
           name: false,
           version: "0.150.1",
           transport_pid: fake_transport,
           sink: sink,
           clock: fn -> @eval_time end,
           base_backoff_ms: 10_000,
           max_backoff_ms: 30_000}
        )

      _ = :sys.get_state(monitor)
      assert_receive {:ingested, initial_snapshot}
      assert initial_snapshot.capacity_state == :observed

      # Simulate transport disconnect
      FakeTransport.simulate_disconnect(fake_transport, :connection_lost)
      _ = :sys.get_state(monitor)

      assert_receive {:ingested, degraded_snapshot}
      assert degraded_snapshot.capacity_state == :degraded
      assert degraded_snapshot.confidence == :low
      assert [p, s] = degraded_snapshot.windows
      assert p.used_percent == 13
      assert s.used_percent == 16

      assert CodexMonitor.status(monitor) == :backoff
      status_map = CodexMonitor.get_status(monitor)
      assert status_map.backoff_attempt == 1
    end

    test "exponential backoff calculates real delay with jitter, caps at max, and clamps hostile backoff_fn" do
      test_pid = self()

      random_fn = fn max ->
        send(test_pid, {:jitter, max})
        div(max, 2)
      end

      monitor2 =
        start_supervised!(%{
          id: :m2,
          start:
            {CodexMonitor, :start_link,
             [
               [
                 name: false,
                 version: "0.150.1",
                 transport: Shoestring.Harness.Capacity.Codex.FakeTransport,
                 transport_opts: [owner: self(), emit_connected: false],
                 base_backoff_ms: 10_000,
                 max_backoff_ms: 30_000,
                 random_fn: random_fn
               ]
             ]}
        })

      status_connecting = CodexMonitor.get_status(monitor2)
      send(monitor2, {:codex_transport_error, status_connecting.transport_pid, :err})
      _ = :sys.get_state(monitor2)

      assert_receive {:jitter, max1}
      assert max1 > 0

      status1 = CodexMonitor.get_status(monitor2)
      assert status1.backoff_attempt == 1
      assert status1.status == :unavailable
      remaining1 = Process.read_timer(status1.reconnect_timer)
      assert remaining1 > 10_000 and remaining1 <= 12_501

      # By using send(monitor2, :reconnect), we bypass CodexMonitor.reconnect/1
      # which intentionally resets backoff_attempt to 0. This ensures attempt 2 logic runs.
      send(monitor2, :reconnect)
      status_connecting2 = CodexMonitor.get_status(monitor2)
      send(monitor2, {:codex_transport_error, status_connecting2.transport_pid, :err})
      _ = :sys.get_state(monitor2)

      assert_receive {:jitter, max2}
      assert max2 > max1

      # Now explicitly test that public reconnect/1 resets the backoff counter
      CodexMonitor.reconnect(monitor2)
      status_connecting_reconnect = CodexMonitor.get_status(monitor2)
      assert status_connecting_reconnect.backoff_attempt == 0

      monitor3 =
        start_supervised!(%{
          id: :m3,
          start:
            {CodexMonitor, :start_link,
             [
               [
                 name: false,
                 version: "0.150.1",
                 transport: Shoestring.Harness.Capacity.Codex.FakeTransport,
                 transport_opts: [owner: self(), emit_connected: false],
                 max_backoff_ms: 30_000,
                 backoff_fn: fn _ -> -5 end
               ]
             ]}
        })

      status_connecting3 = CodexMonitor.get_status(monitor3)
      send(monitor3, {:codex_transport_error, status_connecting3.transport_pid, :err})
      _ = :sys.get_state(monitor3)
      
      assert Process.alive?(monitor3)
      status3 = CodexMonitor.get_status(monitor3)
      assert status3.backoff_attempt == 1
      assert Process.read_timer(status3.reconnect_timer) in [0, false]

      monitor4 =

        start_supervised!(%{
          id: :m4,
          start:
            {CodexMonitor, :start_link,
             [
               [
                 name: false,
                 version: "0.150.1",
                 transport: Shoestring.Harness.Capacity.Codex.FakeTransport,
                 transport_opts: [owner: self(), emit_connected: false],
                 max_backoff_ms: 30_000,
                 backoff_fn: fn _ -> 999_999_999 end
               ]
             ]}
        })

      status_connecting4 = CodexMonitor.get_status(monitor4)
      send(monitor4, {:codex_transport_error, status_connecting4.transport_pid, :err})
      _ = :sys.get_state(monitor4)
      status4 = CodexMonitor.get_status(monitor4)
      remaining4 = Process.read_timer(status4.reconnect_timer)
      assert remaining4 > 29_000 and remaining4 <= 30_000
    end
  end

  describe "malformed and oversized input safety" do
    test "safely rejects malformed JSON string without crashing",
         %{normal_read: normal_read} do
      {:ok, fake_transport} =
        start_supervised(
          {FakeTransport,
           owner: self(), emit_connected: false, auto_respond: default_auto_respond(normal_read)}
        )

      monitor =
        start_supervised!(
          {CodexMonitor,
           name: false,
           version: "0.150.1",
           transport_pid: fake_transport,
           sink: fn s -> {:ok, :persisted, s} end,
           clock: fn -> @eval_time end}
        )

      sync_handshake(monitor, fake_transport)
      assert CodexMonitor.status(monitor) == :connected

      # Push garbage JSON line
      FakeTransport.push_frame(fake_transport, "NOT JSON AT ALL {{{")
      _ = :sys.get_state(monitor)

      # Still connected and healthy
      assert CodexMonitor.status(monitor) == :connected
    end

    test "safely rejects oversized frame without buffer exhaustion",
         %{normal_read: normal_read} do
      {:ok, fake_transport} =
        start_supervised(
          {FakeTransport,
           owner: self(),
           emit_connected: false,
           auto_respond: default_auto_respond(normal_read),
           max_frame_size: 2_000}
        )

      monitor =
        start_supervised!(
          {CodexMonitor,
           name: false,
           version: "0.150.1",
           transport_pid: fake_transport,
           sink: fn s -> {:ok, :persisted, s} end,
           max_frame_size: 2_000,
           clock: fn -> @eval_time end}
        )

      sync_handshake(monitor, fake_transport)
      assert CodexMonitor.status(monitor) == :connected

      # Push an oversized payload exceeding 2,000 bytes
      oversized = %{
        "method" => "account/rateLimits/updated",
        "params" => %{"huge" => String.duplicate("x", 5_000)}
      }

      FakeTransport.push_frame(fake_transport, oversized)
      _ = :sys.get_state(monitor)

      # Does not crash
      assert CodexMonitor.status(monitor) == :backoff
    end
  end

  describe "sink failure and recovery" do
    test "marks :degraded on sink error and recovers on subsequent success",
         %{normal_read: normal_read, sparse_update: sparse_update} do
      test_pid = self()

      agent =
        start_supervised!(%{
          id: :test_sink_state,
          start: {Agent, :start_link, [fn -> :succeed end]}
        })

      sink = fn snapshot ->
        case Agent.get(agent, & &1) do
          :fail ->
            send(test_pid, :sink_failed)
            {:error, :database_unreachable}

          :succeed ->
            send(test_pid, {:ingested, snapshot})
            {:ok, :persisted, snapshot}
        end
      end

      {:ok, fake_transport} =
        start_supervised(
          {FakeTransport,
           owner: self(), emit_connected: false, auto_respond: default_auto_respond(normal_read)}
        )

      monitor =
        start_supervised!(
          {CodexMonitor,
           name: false,
           version: "0.150.1",
           transport_pid: fake_transport,
           sink: sink,
           clock: fn -> @eval_time end}
        )

      _ = :sys.get_state(monitor)
      assert_receive {:ingested, _snapshot}
      assert CodexMonitor.status(monitor) == :connected

      # Set sink to fail
      Agent.update(agent, fn _ -> :fail end)

      FakeTransport.push_notification(
        fake_transport,
        "account/rateLimits/updated",
        sparse_update
      )

      _ = :sys.get_state(monitor)
      assert_receive :sink_failed
      assert CodexMonitor.status(monitor) == :sink_error

      # Set sink to succeed again
      Agent.update(agent, fn _ -> :succeed end)

      FakeTransport.push_notification(
        fake_transport,
        "account/rateLimits/updated",
        sparse_update
      )

      _ = :sys.get_state(monitor)
      assert_receive {:ingested, _recovered_snapshot}
      assert CodexMonitor.status(monitor) == :connected
    end
  end

  describe "secret redaction" do
    test "payloads containing auth tokens or secret patterns are rejected",
         %{normal_read: normal_read} do
      test_pid = self()

      sink = fn snapshot ->
        send(test_pid, {:ingested, snapshot})
        {:ok, :persisted, snapshot}
      end

      {:ok, fake_transport} =
        start_supervised(
          {FakeTransport,
           owner: self(), emit_connected: false, auto_respond: default_auto_respond(normal_read)}
        )

      monitor =
        start_supervised!(
          {CodexMonitor,
           name: false,
           version: "0.150.1",
           transport_pid: fake_transport,
           sink: sink,
           clock: fn -> @eval_time end}
        )

      _ = :sys.get_state(monitor)
      assert_receive {:ingested, initial}

      # Push an update with an illegal secret bearer token pattern
      leak_attempt = %{
        "rateLimits" => %{
          "primary" => %{
            "usedPercent" => 50,
            "windowDurationMins" => 300,
            "resetsAt" => 1_787_994_541
          },
          "auth" => "Bearer sk-secret1234567890abcdef"
        }
      }

      FakeTransport.push_notification(
        fake_transport,
        "account/rateLimits/updated",
        leak_attempt
      )

      _ = :sys.get_state(monitor)

      # The current snapshot was NOT overwritten with the leaking payload
      current = CodexMonitor.last_observation(monitor)
      assert current.snapshot_id == initial.snapshot_id or current.capacity_state == :degraded
      # No secret is in extensions or reason
      refute inspect(current) =~ "sk-secret"
    end
  end

  describe "public API and Capacity.Source behaviour" do
    test "explicit read_capacity works when monitor is in non-optimal but connected states",
         %{normal_read: normal_read} do
      {:ok, fake_transport} =
        start_supervised(
          {FakeTransport,
           owner: self(), emit_connected: true, auto_respond: default_auto_respond(normal_read)}
        )

      monitor =
        start_supervised!(
          {CodexMonitor,
           name: false,
           version: "0.150.1",
           transport_pid: fake_transport,
           sink: fn s -> {:ok, :persisted, s} end,
           clock: fn -> ~U[2026-08-29 04:38:25Z] end}
        )

      _ = :sys.get_state(monitor)

      # Put it into :incompatible_schema (degraded capacity state)
      Shoestring.Harness.Capacity.CodexMonitor.get_status(monitor)
      :sys.replace_state(monitor, fn state -> %{state | status: :incompatible_schema} end)

      assert {:ok, _} = Shoestring.Harness.Capacity.CodexMonitor.read_capacity(monitor, 1000)

      # Put into :refused
      :sys.replace_state(monitor, fn state -> %{state | status: :refused} end)
      assert {:ok, _} = Shoestring.Harness.Capacity.CodexMonitor.read_capacity(monitor, 1000)

      # Put into :sink_error
      :sys.replace_state(monitor, fn state -> %{state | status: :sink_error} end)
      assert {:ok, _} = Shoestring.Harness.Capacity.CodexMonitor.read_capacity(monitor, 1000)

      # Put into :unavailable (should fail)
      :sys.replace_state(monitor, fn state -> %{state | status: :unavailable} end)

      assert {:error, :not_connected} =
               Shoestring.Harness.Capacity.CodexMonitor.read_capacity(monitor, 1000)
    end

    test "implements Shoestring.Harness.Capacity.Source callbacks",
         %{normal_read: normal_read} do
      {:ok, fake_transport} =
        start_supervised(
          {FakeTransport,
           owner: self(), emit_connected: false, auto_respond: default_auto_respond(normal_read)}
        )

      monitor =
        start_supervised!(
          {CodexMonitor,
           name: :test_codex_monitor,
           version: "0.150.1",
           transport_pid: fake_transport,
           sink: fn s -> {:ok, :persisted, s} end,
           clock: fn -> @eval_time end}
        )

      sync_handshake(monitor, fake_transport)

      assert CodexMonitor.provenance() == %{
               adapter_id: "codex_app_server_stdio",
               provider_id: "codex",
               invocation_mode: "app_server_stdio",
               event: :explicit_read
             }

      assert CodexMonitor.support_tier() == :proactive

      assert {:ok, snapshot} = CodexMonitor.observe(:test_codex_monitor)
      assert snapshot.capacity_state == :observed

      # Test alias Shoestring.Harness.CodexMonitor
      assert HarnessCodexMonitor.status(:test_codex_monitor) == :connected
      assert {:ok, _} = HarnessCodexMonitor.observe(:test_codex_monitor)
    end
  end
end
