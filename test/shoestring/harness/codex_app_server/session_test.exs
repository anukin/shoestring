defmodule Shoestring.Harness.CodexAppServer.SessionTest do
  use ExUnit.Case, async: true

  alias Shoestring.Harness.{CodexAppServer, Error, RunIdentity, RunRequest}
  alias Shoestring.Harness.CodexAppServer.Session

  defmodule FakeTestTransport do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    def send_frame(pid, frame) do
      GenServer.call(pid, {:send_frame, frame})
    end

    def os_pid(_pid), do: 99999

    @impl GenServer
    def init(opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      {:ok, %{test_pid: test_pid, sent_frames: []}}
    end

    @impl GenServer
    def handle_call({:send_frame, frame}, _from, state) do
      send(state.test_pid, {:sent_rpc, frame})
      {:reply, :ok, %{state | sent_frames: [frame | state.sent_frames]}}
    end
  end

  defmodule ScriptedTransport do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    def send_frame(pid, frame) do
      GenServer.call(pid, {:send_frame, frame})
    end

    def os_pid(_pid), do: 88888

    @impl GenServer
    def init(opts) do
      owner = Keyword.get(opts, :owner) || Keyword.get(opts, :test_pid)
      canned_thread_id = Keyword.get(opts, :thread_id, "01950000-0000-7000-8000-000000000099")
      canned_turn_id = Keyword.get(opts, :turn_id, "01950000-0000-7000-8000-000000000088")
      mode = Keyword.get(opts, :mode, :normal)

      if owner && is_pid(owner) do
        send(owner, {:codex_transport_connected, self()})
      end

      {:ok,
       %{
         owner: owner,
         sent_frames: [],
         canned_thread_id: canned_thread_id,
         canned_turn_id: canned_turn_id,
         mode: mode
       }}
    end

    @impl GenServer
    def handle_call({:send_frame, frame}, _from, state) do
      frame_map = if is_binary(frame), do: Jason.decode!(frame), else: frame
      state = %{state | sent_frames: [frame_map | state.sent_frames]}

      if state.owner do
        send(state.owner, {:sent_rpc, frame_map})
      end

      case frame_map["method"] do
        "initialize" ->
          if state.mode != :silent_handshake do
            resp = %{
              "jsonrpc" => "2.0",
              "id" => frame_map["id"],
              "result" => %{
                "userAgent" => "codex/0.153.2",
                "platformFamily" => "unix",
                "platformOs" => "darwin"
              }
            }

            reply_frame(state, resp)
          end

        "initialized" ->
          :ok

        "thread/start" ->
          resp = %{
            "jsonrpc" => "2.0",
            "id" => frame_map["id"],
            "result" => %{
              "thread" => %{
                "id" => state.canned_thread_id,
                "sessionId" => state.canned_thread_id,
                "status" => %{"type" => "idle"}
              }
            }
          }

          reply_frame(state, resp)

        "thread/resume" ->
          thread_id = get_in(frame_map, ["params", "threadId"]) || state.canned_thread_id

          resp = %{
            "jsonrpc" => "2.0",
            "id" => frame_map["id"],
            "result" => %{
              "thread" => %{
                "id" => thread_id,
                "sessionId" => thread_id,
                "status" => %{"type" => "idle"}
              }
            }
          }

          reply_frame(state, resp)

        "turn/start" ->
          resp = %{
            "jsonrpc" => "2.0",
            "id" => frame_map["id"],
            "result" => %{
              "turn" => %{
                "id" => state.canned_turn_id,
                "status" => "inProgress"
              }
            }
          }

          reply_frame(state, resp)

        "turn/interrupt" ->
          resp = %{
            "jsonrpc" => "2.0",
            "id" => frame_map["id"],
            "result" => %{}
          }

          reply_frame(state, resp)

        _ ->
          :ok
      end

      {:reply, :ok, state}
    end

    defp reply_frame(state, resp_map) do
      if state.owner do
        send(state.owner, {:codex_transport_frame, self(), Jason.encode!(resp_map)})
      end
    end
  end

  defp make_test_run_request do
    {:ok, req} =
      RunRequest.new(%{
        version: 1,
        goal_id: "00000000-0000-4000-8000-000000000001",
        task_id: "00000000-0000-4000-8000-000000000002",
        workspace_ref: "workspace/contract-test",
        prompt: "Run tests",
        policy: %{mode: "supervised", network: false, write_access: true},
        requested_capabilities: [],
        dispatch_id: "00000000-0000-4000-8000-000000000003"
      })

    req
  end

  describe "happy-path RPC choreography and thread id propagation (B2)" do
    test "scripts initialize -> thread/start -> turn/start responses and returns real thread_id in identity" do
      test_pid = self()
      req = make_test_run_request()
      real_thread_id = "01950000-0000-7000-8000-000000000099"

      {:ok, transport} =
        start_supervised({ScriptedTransport, test_pid: test_pid, thread_id: real_thread_id})

      session =
        start_supervised!(
          {Session,
           run_request: req,
           transport_pid: transport,
           transport: ScriptedTransport,
           owner: test_pid}
        )

      :sys.replace_state(transport, fn state -> %{state | owner: session} end)
      send(session, {:codex_transport_connected, transport})

      {:ok, identity} = Session.await_run_identity(session, 5_000)

      # ASSERTION: returned identity carries the REAL provider thread_id!
      assert identity.provider_session_id == real_thread_id
      assert identity.run_id == req.dispatch_id
      assert identity.harness_id == "codex_app_server_stdio"

      # Verify the session is in turn_in_progress
      {:ok, status} = Session.status(session)
      assert status.status == :turn_in_progress
      assert status.thread_id == real_thread_id
      assert status.turn_id == "01950000-0000-7000-8000-000000000088"
    end

    test "scripts thread/resume response and propagates thread_id on resume" do
      test_pid = self()
      req = make_test_run_request()
      prior_thread_id = "01950000-0000-7000-8000-000000000077"

      {:ok, transport} =
        start_supervised({ScriptedTransport, test_pid: test_pid, thread_id: prior_thread_id})

      session =
        start_supervised!(
          {Session,
           run_request: req,
           transport_pid: transport,
           transport: ScriptedTransport,
           resume: true,
           thread_id: prior_thread_id,
           owner: test_pid}
        )

      :sys.replace_state(transport, fn state -> %{state | owner: session} end)
      send(session, {:codex_transport_connected, transport})

      {:ok, identity} = Session.await_run_identity(session, 5_000)

      # ASSERTION: resumed identity carries the exact prior thread id
      assert identity.provider_session_id == prior_thread_id
    end

    test "fails with handshake_timeout error when initialize response times out" do
      test_pid = self()
      req = make_test_run_request()

      {:ok, transport} =
        start_supervised({ScriptedTransport, test_pid: test_pid, mode: :silent_handshake})

      session =
        start_supervised!(
          {Session,
           run_request: req,
           transport_pid: transport,
           transport: ScriptedTransport,
           handshake_timeout_ms: 100,
           owner: test_pid}
        )

      :sys.replace_state(transport, fn state -> %{state | owner: session} end)
      send(session, {:codex_transport_connected, transport})

      result = Session.await_run_identity(session, 500)

      assert {:error, %Error{} = err} = result
      assert err.category == :transport
      assert err.code == "handshake_timeout"
    end

    test "adapter.start and adapter.resume end-to-end with spawned ScriptedTransport" do
      req = make_test_run_request()
      real_thread_id = "01950000-0000-7000-8000-000000000099"

      # Start adapter session with transport module ScriptedTransport (transport_pid absent)
      assert {:ok, identity} =
               CodexAppServer.start(req, %{
                 transport: ScriptedTransport,
                 handshake_timeout_ms: 5_000
               })

      assert identity.provider_session_id == real_thread_id
      assert is_binary(identity.run_id)

      # Resume adapter session
      assert {:ok, resumed_identity} =
               CodexAppServer.resume(identity, req, %{
                 transport: ScriptedTransport,
                 handshake_timeout_ms: 5_000
               })

      assert resumed_identity.provider_session_id == real_thread_id
    end
  end

  describe "lease safe boundary rule" do
    test "delays turn/interrupt until item.completed when commandExecution is in flight" do
      test_pid = self()
      req = make_test_run_request()

      {:ok, transport} = start_supervised({FakeTestTransport, test_pid: test_pid})

      session =
        start_supervised!(
          {Session,
           run_request: req,
           transport_pid: transport,
           transport: FakeTestTransport,
           auto_handshake: false,
           thread_id: "01950000-0000-7000-8000-000000000001"}
        )

      # Simulate turn started
      send(
        session,
        {:codex_transport_frame, transport,
         Jason.encode!(%{
           "method" => "turn/started",
           "params" => %{
             "turn" => %{"id" => "01950000-0000-7000-8000-000000000002", "status" => "inProgress"}
           }
         })}
      )

      # Simulate commandExecution started
      send(
        session,
        {:codex_transport_frame, transport,
         Jason.encode!(%{
           "method" => "item/started",
           "params" => %{
             "item" => %{
               "type" => "commandExecution",
               "id" => "exec-1",
               "command" => "sleep 10",
               "processId" => "44444",
               "status" => "inProgress"
             }
           }
         })}
      )

      _ = :sys.get_state(session)

      # Request stop at safe boundary while commandExecution is in flight
      assert {:ok, :stop_requested} = Session.request_safe_stop(session)

      # ASSERTION: turn/interrupt must NOT have been sent yet because command is in flight!
      refute_receive {:sent_rpc, %{"method" => "turn/interrupt"}}

      # Now simulate commandExecution completed
      send(
        session,
        {:codex_transport_frame, transport,
         Jason.encode!(%{
           "method" => "item/completed",
           "params" => %{
             "item" => %{
               "type" => "commandExecution",
               "id" => "exec-1",
               "command" => "sleep 10",
               "processId" => "44444",
               "status" => "completed",
               "exitCode" => 0
             }
           }
         })}
      )

      # CRITICAL ASSERTION: turn/interrupt MUST be sent immediately now!
      assert_receive {:sent_rpc,
                      %{
                        "method" => "turn/interrupt",
                        "params" => %{
                          "threadId" => "01950000-0000-7000-8000-000000000001",
                          "turnId" => "01950000-0000-7000-8000-000000000002"
                        }
                      }}

      # Finally simulate turn/completed with status interrupted
      send(
        session,
        {:codex_transport_frame, transport,
         Jason.encode!(%{
           "method" => "turn/completed",
           "params" => %{
             "turn" => %{
               "id" => "01950000-0000-7000-8000-000000000002",
               "status" => "interrupted",
               "durationMs" => 1500
             }
           }
         })}
      )

      _ = :sys.get_state(session)
      {:ok, status} = Session.status(session)
      assert status.status == :interrupted

      {:ok, events} = Session.stream_events(session)
      last_event = List.last(events)
      assert last_event.kind == :result
      assert last_event.result.status == "interrupted"
      assert last_event.extensions["codex-app-server:interrupted"] == true
    end

    test "exercises Session.cancel with boundary: :item (Nit 1)" do
      test_pid = self()
      req = make_test_run_request()

      {:ok, transport} = start_supervised({FakeTestTransport, test_pid: test_pid})

      session =
        start_supervised!(
          {Session,
           run_request: req,
           transport_pid: transport,
           transport: FakeTestTransport,
           auto_handshake: false,
           thread_id: "01950000-0000-7000-8000-000000000001"}
        )

      send(
        session,
        {:codex_transport_frame, transport,
         Jason.encode!(%{
           "method" => "turn/started",
           "params" => %{
             "turn" => %{"id" => "01950000-0000-7000-8000-000000000002", "status" => "inProgress"}
           }
         })}
      )

      send(
        session,
        {:codex_transport_frame, transport,
         Jason.encode!(%{
           "method" => "item/started",
           "params" => %{
             "item" => %{
               "type" => "commandExecution",
               "id" => "exec-2",
               "command" => "sleep 10",
               "processId" => "44445",
               "status" => "inProgress"
             }
           }
         })}
      )

      _ = :sys.get_state(session)

      # Calling cancel with boundary: :item defers interrupt while item is in flight
      assert {:ok, :cancelled} = Session.cancel(session, %{boundary: :item})
      refute_receive {:sent_rpc, %{"method" => "turn/interrupt"}}

      # On item completion, interrupt fires
      send(
        session,
        {:codex_transport_frame, transport,
         Jason.encode!(%{
           "method" => "item/completed",
           "params" => %{
             "item" => %{
               "type" => "commandExecution",
               "id" => "exec-2",
               "command" => "sleep 10",
               "processId" => "44445",
               "status" => "completed",
               "exitCode" => 0
             }
           }
         })}
      )

      assert_receive {:sent_rpc, %{"method" => "turn/interrupt"}}
    end

    test "issues turn/interrupt immediately when stop requested while no item is in flight" do
      test_pid = self()
      req = make_test_run_request()

      {:ok, transport} = start_supervised({FakeTestTransport, test_pid: test_pid})

      session =
        start_supervised!(
          {Session,
           run_request: req,
           transport_pid: transport,
           transport: FakeTestTransport,
           auto_handshake: false,
           thread_id: "01950000-0000-7000-8000-000000000001"}
        )

      send(
        session,
        {:codex_transport_frame, transport,
         Jason.encode!(%{
           "method" => "turn/started",
           "params" => %{
             "turn" => %{"id" => "01950000-0000-7000-8000-000000000002", "status" => "inProgress"}
           }
         })}
      )

      _ = :sys.get_state(session)

      # Stop requested while idle (no item started)
      assert {:ok, :stop_requested} = Session.request_safe_stop(session)

      # Interrupt must be issued immediately
      assert_receive {:sent_rpc, %{"method" => "turn/interrupt"}}
    end

    test "default cancel without boundary interrupts immediately even mid-command (Nit 1)" do
      test_pid = self()
      req = make_test_run_request()

      {:ok, transport} = start_supervised({FakeTestTransport, test_pid: test_pid})

      session =
        start_supervised!(
          {Session,
           run_request: req,
           transport_pid: transport,
           transport: FakeTestTransport,
           auto_handshake: false,
           thread_id: "01950000-0000-7000-8000-000000000001"}
        )

      send(
        session,
        {:codex_transport_frame, transport,
         Jason.encode!(%{
           "method" => "turn/started",
           "params" => %{
             "turn" => %{"id" => "01950000-0000-7000-8000-000000000002", "status" => "inProgress"}
           }
         })}
      )

      send(
        session,
        {:codex_transport_frame, transport,
         Jason.encode!(%{
           "method" => "item/started",
           "params" => %{
             "item" => %{
               "type" => "commandExecution",
               "id" => "exec-3",
               "command" => "sleep 10",
               "processId" => "44446",
               "status" => "inProgress"
             }
           }
         })}
      )

      _ = :sys.get_state(session)

      # Default cancel with %{} interrupts immediately without waiting for boundary
      assert {:ok, :cancelled} = Session.cancel(session, %{})
      assert_receive {:sent_rpc, %{"method" => "turn/interrupt"}}
    end
  end

  describe "line cap fail-closed error handling" do
    test "cancels turn and emits transport error when oversized frame received" do
      test_pid = self()
      req = make_test_run_request()

      {:ok, transport} = start_supervised({FakeTestTransport, test_pid: test_pid})

      session =
        start_supervised!(
          {Session,
           run_request: req,
           transport_pid: transport,
           transport: FakeTestTransport,
           auto_handshake: false,
           thread_id: "01950000-0000-7000-8000-000000000001"}
        )

      send(
        session,
        {:codex_transport_frame, transport,
         Jason.encode!(%{
           "method" => "turn/started",
           "params" => %{
             "turn" => %{"id" => "01950000-0000-7000-8000-000000000002", "status" => "inProgress"}
           }
         })}
      )

      _ = :sys.get_state(session)

      # Transport notifies oversized frame
      send(session, {:codex_transport_error, transport, :oversized_frame})
      _ = :sys.get_state(session)

      # Assert turn/interrupt was attempted
      assert_receive {:sent_rpc, %{"method" => "turn/interrupt"}}

      # Assert error event was buffered
      {:ok, events} = Session.stream_events(session)
      error_event = Enum.find(events, &(&1.kind == :error))
      assert error_event != nil
      assert error_event.error.category == :transport
      assert error_event.error.code == "oversized_frame"

      {:ok, status} = Session.status(session)
      assert status.status == :failed
    end

    test "ignores subsequent frames after entering failed state (Nit 3 terminal guard)" do
      test_pid = self()
      req = make_test_run_request()

      {:ok, transport} = start_supervised({FakeTestTransport, test_pid: test_pid})

      session =
        start_supervised!(
          {Session,
           run_request: req,
           transport_pid: transport,
           transport: FakeTestTransport,
           auto_handshake: false,
           thread_id: "01950000-0000-7000-8000-000000000001"}
        )

      # Enter failed state via oversized frame
      send(session, {:codex_transport_error, transport, :oversized_frame})
      _ = :sys.get_state(session)

      {:ok, initial_events} = Session.stream_events(session)
      initial_count = length(initial_events)

      # Now send subsequent frames
      send(
        session,
        {:codex_transport_frame, transport,
         Jason.encode!(%{
           "method" => "item/started",
           "params" => %{"item" => %{"type" => "userMessage"}}
         })}
      )

      _ = :sys.get_state(session)

      # Terminal guard ensures subsequent frame was ignored
      {:ok, final_events} = Session.stream_events(session)
      assert length(final_events) == initial_count
    end
  end

  describe "streaming delta shapes through the full Session path (live-demo regression)" do
    @streaming_fixture Path.expand(
                         "../../../../plans/evidence/04-single-elf/fixtures/codex/app-server-streaming-deltas.json",
                         __DIR__
                       )

    test "bare-string and map deltas buffer live; malformed frames are logged, counted, and skipped" do
      test_pid = self()
      req = make_test_run_request()
      thread_id = "01950000-0000-7000-8000-000000000001"

      {:ok, transport} = start_supervised({FakeTestTransport, test_pid: test_pid})

      session =
        start_supervised!(
          {Session,
           run_request: req,
           transport_pid: transport,
           transport: FakeTestTransport,
           auto_handshake: false,
           thread_id: thread_id}
        )

      send_frame = fn frame ->
        send(session, {:codex_transport_frame, transport, Jason.encode!(frame)})
      end

      # Pre-existing buffered state, mirroring the demo run's live-buffered
      # events that died with the Session before the fix.
      send_frame.(%{
        "method" => "turn/started",
        "params" => %{"turn" => %{"id" => "01950000-0000-7000-8000-000000000003"}}
      })

      send_frame.(%{
        "method" => "item/started",
        "params" => %{
          "threadId" => thread_id,
          "item" => %{
            "type" => "agentMessage",
            "id" => "msg_0000000000000000000000000000000000000000000000000000000000000001",
            "phase" => "commentary"
          }
        }
      })

      _ = :sys.get_state(session)
      {:ok, pre_events} = Session.stream_events(session)
      assert length(pre_events) == 2

      # The committed streaming fixture: bare-string delta, map delta,
      # malformed integer delta, and a raising null-params turn shape.
      fixture = @streaming_fixture |> File.read!() |> Jason.decode!()
      assert length(fixture["frames"]) == 4

      for frame <- fixture["frames"] do
        send_frame.(frame)
      end

      _ = :sys.get_state(session)

      # The session survived every frame — nothing took it down and no
      # buffered event was lost.
      assert Process.alive?(session)

      {:ok, events} = Session.stream_events(session)
      assert length(events) == 4

      deltas =
        events
        |> Enum.filter(
          &(&1.kind == :output and
              &1.extensions["codex-app-server:method"] == "item/agentMessage/delta")
        )
        |> Enum.map(& &1.extensions["codex-app-server:delta"])

      assert "I" in deltas
      assert "hello" in deltas

      # The pre-existing turn/started lifecycle event is intact, and the
      # garbage turn frame never corrupted the turn tracking.
      assert hd(events).kind == :lifecycle
      {:ok, status} = Session.status(session)
      assert status.status == :turn_in_progress
      assert status.turn_id == "01950000-0000-7000-8000-000000000003"

      # Both unparseable frames were counted: the integer delta (explicit
      # error) and the raising turn shape (rescued backstop).
      assert status.malformed_lines == 2
      assert status.event_count == 4
    end

    test "non-JSON bytes and non-object frames are counted without killing the session" do
      test_pid = self()
      req = make_test_run_request()

      {:ok, transport} = start_supervised({FakeTestTransport, test_pid: test_pid})

      session =
        start_supervised!(
          {Session,
           run_request: req,
           transport_pid: transport,
           transport: FakeTestTransport,
           auto_handshake: false,
           thread_id: "01950000-0000-7000-8000-000000000001"}
        )

      send(session, {:codex_transport_frame, transport, "this is not json"})
      send(session, {:codex_transport_frame, transport, Jason.encode!([1, 2, 3])})
      _ = :sys.get_state(session)

      assert Process.alive?(session)
      {:ok, status} = Session.status(session)
      assert status.malformed_lines == 2
      {:ok, events} = Session.stream_events(session)
      assert events == []
    end
  end

  describe "adapter status and error behavior (Nit 4)" do
    test "adapter.status/2 returns status :unknown on missing/unknown session" do
      {:ok, unknown_id} =
        RunIdentity.new(%{
          run_id: "00000000-0000-4000-8000-000000000099",
          harness_id: "codex_app_server_stdio",
          process_id: "os-pid-999",
          provider_session_id: "01950000-0000-7000-8000-000000000099"
        })

      assert {:ok, %{status: :unknown}} = CodexAppServer.status(unknown_id)
    end
  end
end
