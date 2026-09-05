defmodule Shoestring.Elves.LeaseBoundaryTest do
  use ExUnit.Case, async: true

  alias Shoestring.Elves.LeaseBoundary
  alias Shoestring.Elves.LeaseWatcher
  alias Shoestring.Harness.CodexAppServer.Session
  alias Shoestring.Harness.RunRequest

  defmodule BoundaryTransport do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def send_frame(pid, frame), do: GenServer.call(pid, {:send_frame, frame})
    def os_pid(_pid), do: 99991

    @impl GenServer
    def init(opts) do
      {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}
    end

    @impl GenServer
    def handle_call({:send_frame, frame}, _from, state) do
      send(state.test_pid, {:sent_rpc, frame})
      {:reply, :ok, state}
    end
  end

  @forbidden_shapes [
    "cancel_run",
    "cancel_dispatch",
    "killpg",
    "Process.exit",
    "elf-terminal:",
    "Classifier.",
    "Elf.cancel",
    "terminate_owned_group",
    "terminate_pgid"
  ]

  defp run_request do
    {:ok, req} =
      RunRequest.new(%{
        version: 1,
        goal_id: "00000000-0000-4000-8000-000000000001",
        task_id: "00000000-0000-4000-8000-000000000002",
        workspace_ref: "workspace/lease-test",
        prompt: "Run tests",
        policy: %{mode: "supervised", network: false, write_access: true},
        requested_capabilities: [],
        dispatch_id: "00000000-0000-4000-8000-000000000003"
      })

    req
  end

  defp start_session(thread_id \\ "01950000-0000-7000-8000-000000000001") do
    test_pid = self()
    {:ok, transport} = start_supervised({BoundaryTransport, test_pid: test_pid})

    session =
      start_supervised!(
        {Session,
         run_request: run_request(),
         transport_pid: transport,
         transport: BoundaryTransport,
         auto_handshake: false,
         thread_id: thread_id}
      )

    {session, transport}
  end

  defp turn_started(session, transport, turn_id) do
    send(
      session,
      {:codex_transport_frame, transport,
       Jason.encode!(%{
         "method" => "turn/started",
         "params" => %{"turn" => %{"id" => turn_id, "status" => "inProgress"}}
       })}
    )

    _ = :sys.get_state(session)
  end

  defp item_started(session, transport, exec_id, pid) do
    send(
      session,
      {:codex_transport_frame, transport,
       Jason.encode!(%{
         "method" => "item/started",
         "params" => %{
           "item" => %{
             "type" => "commandExecution",
             "id" => exec_id,
             "command" => "mix test",
             "processId" => pid,
             "status" => "inProgress"
           }
         }
       })}
    )

    _ = :sys.get_state(session)
  end

  defp item_completed(session, transport, exec_id, pid) do
    send(
      session,
      {:codex_transport_frame, transport,
       Jason.encode!(%{
         "method" => "item/completed",
         "params" => %{
           "item" => %{
             "type" => "commandExecution",
             "id" => exec_id,
             "command" => "mix test",
             "processId" => pid,
             "status" => "completed",
             "exitCode" => 0
           }
         }
       })}
    )

    _ = :sys.get_state(session)
  end

  test "expired?/2 is a pure deadline comparison" do
    deadline = ~U[2026-09-05 12:00:00Z]
    refute LeaseBoundary.expired?(deadline, ~U[2026-09-05 11:59:59Z])
    assert LeaseBoundary.expired?(deadline, ~U[2026-09-05 12:00:00Z])
    assert LeaseBoundary.expired?(deadline, ~U[2026-09-05 12:00:01Z])
  end

  test "within-lease deadline requests nothing" do
    {session, transport} = start_session()
    turn_started(session, transport, "01950000-0000-7000-8000-000000000002")
    item_started(session, transport, "exec-1", "44444")

    future = DateTime.add(DateTime.utc_now(), 3_600, :second)
    assert {:ok, :within_lease} = LeaseBoundary.enforce(session, future)

    {:ok, status} = Session.status(session)
    assert status.stop_requested == nil
    refute_receive {:sent_rpc, %{"method" => "turn/interrupt"}}
  end

  test "lease deadline during a command item: stop requested, in-flight completes, interrupt follows" do
    {session, transport} = start_session()
    turn_id = "01950000-0000-7000-8000-000000000002"
    turn_started(session, transport, turn_id)
    item_started(session, transport, "exec-1", "44444")

    # Inject the deadline DURING the tool/command item.
    past = DateTime.add(DateTime.utc_now(), -1, :second)
    assert {:ok, :stop_requested} = LeaseBoundary.enforce(session, past)

    # The stop is requested but must NOT interrupt the in-flight item.
    {:ok, status} = Session.status(session)
    assert status.stop_requested == :safe_boundary
    refute_receive {:sent_rpc, %{"method" => "turn/interrupt"}}

    # The in-flight item completes normally: its completion is buffered.
    item_completed(session, transport, "exec-1", "44444")

    {:ok, events} = Session.stream_events(session)

    assert Enum.any?(events, fn event ->
             event.kind == :command and
               event.extensions["codex-app-server:item_id"] == "exec-1"
           end)

    # Only AFTER item.completed does the turn interrupt fire.
    assert_receive {:sent_rpc,
                    %{
                      "method" => "turn/interrupt",
                      "params" => %{"turnId" => ^turn_id}
                    }}

    # Drive the provider's answer all the way through: the interrupted turn
    # completes, and the session reports it honestly — interrupted, never a
    # task failure — with the completed item evidence already buffered
    # before teardown.
    send(
      session,
      {:codex_transport_frame, transport,
       Jason.encode!(%{
         "method" => "turn/completed",
         "params" => %{
           "turn" => %{
             "id" => turn_id,
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
    command_events = Enum.filter(events, &(&1.kind == :command))
    result_events = Enum.filter(events, &(&1.kind == :result))
    assert length(command_events) >= 1
    assert length(result_events) == 1

    [result] = result_events
    assert result.result.status == "interrupted"
    assert result.extensions["codex-app-server:interrupted"] == true

    # Evidence precedes the outcome: every item event was buffered before
    # the turn result that ended the turn.
    assert Enum.all?(command_events, &(&1.ordinal < result.ordinal))
  end

  test "watcher enforces once at the deadline and then stops" do
    {session, transport} = start_session()
    turn_started(session, transport, "01950000-0000-7000-8000-000000000002")
    item_started(session, transport, "exec-1", "44444")

    past = DateTime.add(DateTime.utc_now(), -1, :second)

    watcher =
      start_supervised!(
        {LeaseWatcher,
         session: session, deadline: past, interval_ms: 60_000, now_fun: &DateTime.utc_now/0}
      )

    ref = Process.monitor(watcher)
    assert {:ok, :stop_requested} = LeaseWatcher.check(watcher)
    assert_receive {:DOWN, ^ref, :process, ^watcher, :normal}

    # Requested, not forced: still no interrupt while the item is in flight.
    {:ok, status} = Session.status(session)
    assert status.stop_requested == :safe_boundary
    refute_receive {:sent_rpc, %{"method" => "turn/interrupt"}}

    item_completed(session, transport, "exec-1", "44444")
    assert_receive {:sent_rpc, %{"method" => "turn/interrupt"}}
  end

  test "lease boundary modules carry no termination paths (pinning)" do
    for file <- [
          "lib/shoestring/elves/lease_boundary.ex",
          "lib/shoestring/elves/lease_watcher.ex"
        ] do
      source = File.read!(Path.join(File.cwd!(), file))

      for shape <- @forbidden_shapes do
        refute String.contains?(source, shape),
               "expected #{file} to contain no #{inspect(shape)} (deadline is evidence, stop is at the boundary)"
      end
    end
  end
end
