defmodule Shoestring.Harness.CodexAppServer.AdapterIsolationTest do
  use ExUnit.Case, async: false

  alias Shoestring.Harness.CodexAppServer
  alias Shoestring.Harness.CodexAppServer.EventNormalizer
  alias Shoestring.Harness.Capacity.CodexMonitor
  alias Shoestring.Harness.Capacity.Codex.FakeTransport

  @eval_time ~U[2026-08-29 04:38:25Z]

  setup do
    normal_read = %{
      "rateLimits" => %{
        "primary" => %{
          "usedPercent" => 20,
          "windowDurationMins" => 300,
          "resetsAt" => 1_788_585_939
        },
        "secondary" => %{
          "usedPercent" => 40,
          "windowDurationMins" => 10080,
          "resetsAt" => 1_788_753_130
        }
      }
    }

    auto_respond = fn
      %{"method" => "initialize", "id" => id} ->
        %{"id" => id, "result" => %{"platformFamily" => "unix", "platformOs" => "macos"}}

      %{"method" => "account/read", "id" => id} ->
        %{"id" => id, "result" => %{"account" => %{"type" => "chatgpt"}}}

      %{"method" => "account/rateLimits/read", "id" => id} ->
        %{"id" => id, "result" => normal_read}

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
         name: :isolated_test_monitor,
         version: "0.150.1",
         transport_pid: fake_transport,
         sink: fn snap -> {:ok, :persisted, snap} end,
         clock: fn -> @eval_time end,
         base_backoff_ms: 50,
         max_backoff_ms: 100}
      )

    _ = :sys.get_state(monitor)
    {:ok, monitor: monitor}
  end

  describe "adapter isolation" do
    test "malformed frames in adapter parser do not crash or corrupt the capacity monitor", %{
      monitor: monitor
    } do
      valid_uuid = "00000000-0000-4000-8000-000000000001"

      # 1. Feed malformed JSON and corrupted payloads into EventNormalizer
      assert {:skip, :unhandled_frame} =
               EventNormalizer.normalize(%{"corrupted" => true}, valid_uuid, 1, %{})

      assert {:skip, :unhandled_method} =
               EventNormalizer.normalize(
                 %{"method" => "unknown/broken_method"},
                 valid_uuid,
                 1,
                 %{}
               )

      assert {:skip, :unhandled_frame} =
               EventNormalizer.normalize(nil, valid_uuid, 1, %{})

      # 2. Feed frames with malformed internal structures
      bad_item_frame = %{
        "method" => "item/completed",
        "params" => %{"item" => nil}
      }

      # Should not raise an unhandled crash that collapses anything
      result = EventNormalizer.normalize(bad_item_frame, valid_uuid, 1, %{})
      assert match?({:skip, _}, result) or match?({:error, _}, result)

      # 3. Call adapter methods with invalid simulation flags
      assert {:error, _} = CodexAppServer.probe(%{simulate: :quota_refused})

      # 4. ASSERTION: CodexMonitor remains alive and completely unaffected
      assert Process.alive?(monitor)
      monitor_status = CodexMonitor.status(:isolated_test_monitor)

      assert monitor_status in [
               :connected,
               :refused,
               :incompatible_schema,
               :disconnected,
               :unavailable
             ]
    end

    test "an unexpected crash in an adapter session does not take down the monitor", %{
      monitor: monitor
    } do
      {:ok, req} =
        Shoestring.Harness.RunRequest.new(%{
          version: 1,
          goal_id: "00000000-0000-4000-8000-000000000001",
          task_id: "00000000-0000-4000-8000-000000000002",
          workspace_ref: "workspace/test",
          prompt: "test isolation",
          policy: %{mode: "supervised", network: false, write_access: true},
          requested_capabilities: [],
          dispatch_id: "00000000-0000-4000-8000-000000000003"
        })

      # Start an unlinked real Session process
      {:ok, session_pid} =
        Shoestring.Harness.CodexAppServer.Session.start_link(
          run_request: req,
          auto_handshake: false,
          thread_id: "01950000-0000-7000-8000-000000000001"
        )

      Process.unlink(session_pid)
      session_ref = Process.monitor(session_pid)

      # Induce an abrupt crash in the real Session
      Process.exit(session_pid, :kill)
      assert_receive {:DOWN, ^session_ref, :process, ^session_pid, :killed}

      # ASSERTION: The capacity monitor continues running without interruption
      assert Process.alive?(monitor)

      assert CodexMonitor.status(:isolated_test_monitor) in [
               :connected,
               :refused,
               :incompatible_schema,
               :disconnected,
               :unavailable
             ]
    end
  end
end
