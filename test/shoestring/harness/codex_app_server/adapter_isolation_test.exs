defmodule Shoestring.Harness.CodexAppServer.AdapterIsolationTest do
  use ExUnit.Case, async: false

  alias Shoestring.Harness.Capacity.CodexMonitor
  alias Shoestring.Harness.Capacity.Codex.FakeTransport
  alias Shoestring.Harness.CodexAppServer.Session

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

    test_pid = self()

    monitor =
      start_supervised!(
        {CodexMonitor,
         name: :isolated_test_monitor,
         version: "0.150.1",
         transport_pid: fake_transport,
         sink: fn snap ->
           send(test_pid, {:isolated_snapshot, snap})
           {:ok, :persisted, snap}
         end,
         clock: fn -> @eval_time end,
         base_backoff_ms: 50,
         max_backoff_ms: 100}
      )

    _ = :sys.get_state(monitor)
    {:ok, monitor: monitor, fake_transport: fake_transport, normal_read: normal_read}
  end

  describe "adapter isolation" do
    test "malformed JSON frames are skipped by a live session without affecting the monitor", %{
      monitor: monitor,
      fake_transport: fake_transport,
      normal_read: normal_read
    } do
      # Documents the production behaviour the reviewer observed: corrupted
      # frames do NOT crash Session -- handle_info logs and keeps state. This
      # is a property check on the log-and-skip path, not a fault injection.
      {:ok, session_pid} = start_isolated_session()
      session_ref = Process.monitor(session_pid)

      send(session_pid, {:codex_transport_frame, self(), "{not valid json"})
      send(session_pid, {:codex_transport_frame, self(), ""})

      # Call barrier: proves every prior frame was handled before asserting.
      assert {:ok, %{status: :starting}} = Session.status(session_pid)
      refute_received {:DOWN, ^session_ref, :process, ^session_pid, _}

      assert_monitor_emitting(monitor, fake_transport, normal_read)
    end

    test "a parser-process crash leaves the sibling monitor emitting (fault containment)",
         %{
           monitor: monitor,
           fake_transport: fake_transport,
           normal_read: normal_read
         } do
      # History of this eval, stated plainly: it previously fed
      # `turn/started` with string params and required the Session parser to
      # CRASH with FunctionClauseError out of EventNormalizer. The D2
      # hardening (rescue backstop in Session.handle_info plus tolerant
      # delta shapes in EventNormalizer) now survives that exact frame by
      # design — no frame can crash the parser anymore, so the old
      # frame-to-crash injection no longer crashes anything. That is the
      # code getting more correct, not a regression, and the D2 fix is
      # deliberately NOT weakened to make the old injection crash again.
      #
      # What this eval now proves, in two explicit halves on the same
      # parser process:
      # 1. the old poison frame is survived: counted as malformed, skipped,
      #    session still alive with no DOWN;
      # 2. fault containment still holds when the parser DOES die: the
      #    crash is injected as an unhandled synchronous call — a genuine
      #    FunctionClauseError inside Session.handle_call/3 (not an
      #    external kill) — and the sibling monitor must still be emitting
      #    afterwards, not merely alive.
      {:ok, session_pid} = start_isolated_session()
      Process.unlink(session_pid)
      session_ref = Process.monitor(session_pid)

      poison = Jason.encode!(%{"method" => "turn/started", "params" => "corrupted-not-a-map"})
      send(session_pid, {:codex_transport_frame, self(), poison})

      # Half 1: the hardened parser survives the frame that used to kill it.
      assert {:ok, %{status: :starting, malformed_lines: 1}} =
               Session.status(session_pid)

      refute_received {:DOWN, ^session_ref, :process, ^session_pid, _}

      # Half 2: a genuine parser-process crash, injected past the frame
      # backstop via an unhandled call. The caller exits too (linked call
      # into a dying server), so catch the exit to observe the DOWN.
      _ =
        try do
          GenServer.call(session_pid, :__simulated_parser_fault__)
        catch
          :exit, _ -> :crashed
        end

      assert_receive {:DOWN, ^session_ref, :process, ^session_pid, reason}, 5_000

      # The parser died inside its own handler, not by external kill.
      assert {:function_clause, stack} = reason,
             "expected the parser to die in its own handler, got: #{inspect(reason)}"

      assert Enum.any?(stack, fn {mod, _, _, _} -> mod == Session end)

      # The sibling is BOTH still alive AND still emitting: a fresh snapshot
      # arrives after the failure, not merely Process.alive?.
      assert Process.alive?(monitor)
      assert_monitor_emitting(monitor, fake_transport, normal_read)
    end
  end

  defp start_isolated_session do
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

    {:ok, session_transport} =
      start_supervised(
        {FakeTransport, owner: self(), emit_connected: false},
        id: :isolated_session_transport
      )

    Session.start_link(
      run_request: req,
      auto_handshake: false,
      transport: FakeTransport,
      transport_pid: session_transport,
      thread_id: "01950000-0000-7000-8000-000000000001"
    )
  end

  defp assert_monitor_emitting(monitor, fake_transport, normal_read) do
    FakeTransport.push_notification(
      fake_transport,
      "account/rateLimits/updated",
      put_in(normal_read, ["rateLimits", "primary", "usedPercent"], 21)
    )

    _ = :sys.get_state(monitor)
    assert_receive {:isolated_snapshot, %{source: %{event: :update_notification}}}, 5_000

    snapshot = CodexMonitor.last_observation(:isolated_test_monitor)
    assert snapshot.windows != []
    assert hd(snapshot.windows).used_percent == 21.0
  end
end
