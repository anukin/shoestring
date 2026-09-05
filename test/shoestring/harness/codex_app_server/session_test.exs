defmodule Shoestring.Harness.CodexAppServer.SessionTest do
  use ExUnit.Case, async: true

  alias Shoestring.Harness.CodexAppServer.Session
  alias Shoestring.Harness.RunRequest

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
      assert last_event.result.status == "accepted"
      assert last_event.extensions["codex-app-server:interrupted"] == true
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
  end
end
