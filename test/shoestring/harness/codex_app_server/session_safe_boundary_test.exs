defmodule Shoestring.Harness.CodexAppServer.SessionSafeBoundaryTest do
  @moduledoc """
  Hermetic regression tests for the identity-keyed safe-stop boundary
  (lease-stop interruption must never cut an observably running tool).

  Each test drives a real `Session` with scripted provider frames through a
  recording transport double — never a provider CLI, never the network.

  Locking note (standing contract): requests never send synchronously and
  only streaming deltas / reasoning starts release a pended stop. On the
  pre-fix commits (`1566acd` single slot; `e675c3b` interrupt-on-completion
  and interrupt-on-request) every test asserting "no interrupt yet" fails
  behaviourally — the interrupt arrives at the first unrelated completion
  or at request time with an empty set. The immediate-cancel reap test is
  documentation: that path is unchanged and passes on both.
  """

  use ExUnit.Case, async: true

  alias Shoestring.Elves.LeaseBoundary
  alias Shoestring.Elves.PortRunner
  alias Shoestring.Harness.CodexAppServer.Session
  alias Shoestring.Harness.RunRequest

  defmodule RecordingTransport do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def send_frame(pid, frame), do: GenServer.call(pid, {:send_frame, frame})
    def os_pid(pid), do: GenServer.call(pid, :os_pid)

    @impl GenServer
    def init(opts) do
      {:ok,
       %{
         test_pid: Keyword.fetch!(opts, :test_pid),
         os_pid_override: Keyword.get(opts, :os_pid_override, 999_001)
       }}
    end

    @impl GenServer
    def handle_call({:send_frame, frame}, _from, state) do
      send(state.test_pid, {:sent_rpc, frame})
      {:reply, :ok, state}
    end

    def handle_call(:os_pid, _from, state) do
      {:reply, state.os_pid_override, state}
    end
  end

  @thread_id "01950000-0000-7000-8000-000000000101"
  @turn_id "01950000-0000-7000-8000-000000000102"

  defp run_request do
    {:ok, req} =
      RunRequest.new(%{
        version: 1,
        goal_id: "00000000-0000-4000-8000-000000000001",
        task_id: "00000000-0000-4000-8000-000000000002",
        workspace_ref: "workspace/safe-boundary-test",
        prompt: "Run tests",
        policy: %{mode: "supervised", network: false, write_access: true},
        requested_capabilities: [],
        dispatch_id: "00000000-0000-4000-8000-000000000003"
      })

    req
  end

  defp start_session(opts \\ []) do
    test_pid = self()
    tag = System.unique_integer([:positive, :monotonic])

    transport_opts =
      [test_pid: test_pid] ++ Keyword.take(opts, [:os_pid_override])

    {:ok, transport} =
      start_supervised({RecordingTransport, transport_opts}, id: {:transport, tag})

    session =
      start_supervised!(
        {Session,
         [
           run_request: run_request(),
           transport_pid: transport,
           transport: RecordingTransport,
           auto_handshake: false,
           thread_id: @thread_id
         ]},
        id: {:session, tag}
      )

    send_frame(session, transport, %{
      "method" => "turn/started",
      "params" => %{"turn" => %{"id" => @turn_id, "status" => "inProgress"}}
    })

    {session, transport}
  end

  defp send_frame(session, transport, frame) do
    send(session, {:codex_transport_frame, transport, Jason.encode!(frame)})
    # GenServer.call barrier: the frame was fully handled before this returns.
    _ = :sys.get_state(session)
    :ok
  end

  defp item_started(item),
    do: %{"method" => "item/started", "params" => %{"item" => item}}

  defp item_completed(item),
    do: %{"method" => "item/completed", "params" => %{"item" => item}}

  defp command(id, pid, status \\ "inProgress", extra \\ %{}) do
    %{
      "type" => "commandExecution",
      "id" => id,
      "command" => "sleep 10",
      "processId" => pid,
      "status" => status
    }
    |> Map.merge(extra)
  end

  defp command_done(id, pid),
    do: command(id, pid, "completed", %{"exitCode" => 0})

  defp reasoning(id), do: %{"type" => "reasoning", "id" => id}

  defp message_started(id),
    do: %{"type" => "agentMessage", "id" => id, "phase" => "commentary"}

  defp message_done(id),
    do: %{
      "type" => "agentMessage",
      "id" => id,
      "phase" => "commentary",
      "text" => "done"
    }

  defp file_change(id, status),
    do: %{"type" => "fileChange", "id" => id, "status" => status}

  defp unknown_tool(id),
    do: %{"type" => "mcpToolCall", "id" => id, "status" => "inProgress"}

  defp unknown_tool_done(id),
    do: %{"type" => "mcpToolCall", "id" => id, "status" => "completed"}

  defp delta(text),
    do: %{"method" => "item/agentMessage/delta", "params" => %{"delta" => text}}

  defp turn_completed(status),
    do: %{
      "method" => "turn/completed",
      "params" => %{"turn" => %{"id" => @turn_id, "status" => status}}
    }

  defp interrupt_params do
    %{
      "method" => "turn/interrupt",
      "params" => %{"threadId" => @thread_id, "turnId" => @turn_id}
    }
  end

  defp assert_interrupt do
    assert_receive {:sent_rpc, %{"method" => "turn/interrupt"} = frame}
    assert frame["params"] == interrupt_params()["params"]
  end

  defp refute_interrupt, do: refute_receive({:sent_rpc, %{"method" => "turn/interrupt"}})

  test "reasoning completion with its start does not release a pending stop while a command is open" do
    {session, transport} = start_session()

    send_frame(session, transport, item_started(command("exec-1", "1001")))
    send_frame(session, transport, item_started(reasoning("r-1")))

    assert {:ok, :stop_requested} = Session.request_safe_stop(session)
    refute_interrupt()

    # The reasoning completion must not clear the open command.
    send_frame(session, transport, item_completed(reasoning("r-1")))
    refute_interrupt()

    # Draining the last tool arms the stop but still sends nothing.
    send_frame(session, transport, item_completed(command_done("exec-1", "1001")))
    refute_interrupt()

    # A streaming delta releases the pending stop exactly once.
    send_frame(session, transport, delta("more"))
    assert_interrupt()

    # A later reasoning start sends nothing more.
    send_frame(session, transport, item_started(reasoning("r-2")))
    refute_interrupt()
  end

  test "reasoning completion without its start is ignored while a command is open" do
    {session, transport} = start_session()

    send_frame(session, transport, item_started(command("exec-1", "1002")))
    assert {:ok, :stop_requested} = Session.request_safe_stop(session)

    # A completion for an id that was never opened closes nothing.
    send_frame(session, transport, item_completed(reasoning("r-unseen")))
    refute_interrupt()

    send_frame(session, transport, item_completed(command_done("exec-1", "1002")))
    refute_interrupt()

    send_frame(session, transport, delta("done"))
    assert_interrupt()
  end

  test "message completion does not clear an open command; a later stop still waits" do
    {session, transport} = start_session()

    send_frame(session, transport, item_started(command("exec-1", "1003")))

    # A message completing beside the running command releases nothing:
    # no stop is even pending, and nothing sends.
    send_frame(session, transport, item_completed(message_done("msg-1")))
    refute_interrupt()

    assert {:ok, :stop_requested} = Session.request_safe_stop(session)
    refute_interrupt()

    send_frame(session, transport, item_completed(command_done("exec-1", "1003")))
    refute_interrupt()

    # A begun thinking segment releases the stop.
    send_frame(session, transport, item_started(reasoning("r-1")))
    assert_interrupt()
  end

  test "overlapping commands each hold the pending stop until every one finishes" do
    {session, transport} = start_session()

    send_frame(session, transport, item_started(command("exec-A", "1011")))
    send_frame(session, transport, item_started(command("exec-B", "1012")))

    assert {:ok, :stop_requested} = Session.request_safe_stop(session)
    refute_interrupt()

    send_frame(session, transport, item_completed(command_done("exec-A", "1011")))
    refute_interrupt()

    send_frame(session, transport, item_completed(command_done("exec-B", "1012")))
    refute_interrupt()

    send_frame(session, transport, delta("done"))
    assert_interrupt()
    refute_interrupt()
  end

  # LOCK (fails behaviourally on 1566acd and on e675c3b): the 139→140
  # shape from the committed trace
  # (normalized-codex-lease-stop-final.md). A message completion with an
  # empty open set must not release the stop — the provider routinely
  # starts the next tool immediately after completing commentary. Only a
  # later streaming delta releases it.
  test "message completion with an empty set does not release the stop" do
    {session, transport} = start_session()

    send_frame(session, transport, item_started(command("exec-1", "1013")))
    assert {:ok, :stop_requested} = Session.request_safe_stop(session)

    send_frame(session, transport, item_completed(command_done("exec-1", "1013")))
    refute_interrupt()

    send_frame(session, transport, item_completed(message_done("msg-1")))
    refute_interrupt()

    {:ok, status} = Session.status(session)
    assert status.stop_requested == :safe_boundary

    send_frame(session, transport, delta("done"))
    assert_interrupt()
    refute_interrupt()
  end

  test "file change plus reasoning: completions never release while the write is open" do
    {session, transport} = start_session()

    send_frame(session, transport, item_started(file_change("fc-1", "inProgress")))
    assert {:ok, :stop_requested} = Session.request_safe_stop(session)

    # A reasoning start beside the open write releases nothing.
    send_frame(session, transport, item_started(reasoning("r-1")))
    refute_interrupt()

    # A fresh episode for the completion half: reasoning completions and
    # the tool drain release nothing; only a later delta does.
    {session2, transport2} = start_session()
    send_frame(session2, transport2, item_started(file_change("fc-2", "inProgress")))
    assert {:ok, :stop_requested} = Session.request_safe_stop(session2)

    send_frame(session2, transport2, item_completed(reasoning("r-9")))
    refute_interrupt()

    send_frame(session2, transport2, item_completed(file_change("fc-2", "completed")))
    refute_interrupt()

    send_frame(session2, transport2, item_completed(message_done("msg-9")))
    refute_interrupt()

    send_frame(session2, transport2, delta("done"))
    assert_interrupt()
  end

  test "unknown tool types fail conservatively until their matching completion" do
    {session, transport} = start_session()

    send_frame(session, transport, item_started(unknown_tool("x-1")))
    assert {:ok, :stop_requested} = Session.request_safe_stop(session)

    # A message completing beside the unknown tool releases nothing.
    send_frame(session, transport, item_completed(message_done("msg-1")))
    refute_interrupt()

    send_frame(session, transport, item_completed(unknown_tool_done("x-1")))
    refute_interrupt()

    send_frame(session, transport, delta("done"))
    assert_interrupt()
  end

  test "unidentifiable tool start blocks until the natural terminal" do
    {session, transport} = start_session()

    # No id and no processId: nothing later can match it, so it must
    # fail closed instead of looking like an empty map.
    send_frame(session, transport, item_started(%{"type" => "weirdTool"}))
    assert {:ok, :stop_requested} = Session.request_safe_stop(session)

    send_frame(session, transport, item_completed(message_done("msg-1")))
    refute_interrupt()

    send_frame(session, transport, delta("done"))
    refute_interrupt()

    send_frame(session, transport, turn_completed("interrupted"))
    refute_interrupt()

    {:ok, status} = Session.status(session)
    assert status.status == :interrupted
    assert status.stop_requested == nil
  end

  test "compound exec: command completion followed by a file change never interrupts mid-item" do
    {session, transport} = start_session()

    send_frame(session, transport, item_started(command("exec-1", "1021")))
    assert {:ok, :stop_requested} = Session.request_safe_stop(session)
    refute_interrupt()

    # First nested completion drains the map but sends nothing: the
    # file change START may already be on its way.
    send_frame(session, transport, item_completed(command_done("exec-1", "1021")))
    refute_interrupt()

    send_frame(session, transport, item_started(file_change("fc-1", "inProgress")))
    refute_interrupt()

    send_frame(session, transport, item_completed(file_change("fc-1", "completed")))
    refute_interrupt()

    send_frame(session, transport, delta("done"))
    assert_interrupt()
    refute_interrupt()
  end

  # LOCK (fails behaviourally on e675c3b and 1566acd): the Elf-driven
  # shape from the committed trace (command end 141, bookkeeping 142-143,
  # fileChange start 144). The deadline stop is requested through the
  # Elf's own boundary module AFTER the command completed; the fileChange
  # starts while the request is pending. Neither the request nor the drain
  # may send: the write must survive until model activity or the terminal.
  test "elf deadline stop between command completion and fileChange start sends nothing" do
    {session, transport} = start_session()

    send_frame(session, transport, item_started(command("exec-1", "1021")))
    send_frame(session, transport, item_completed(command_done("exec-1", "1021")))

    past = DateTime.add(DateTime.utc_now(), -1, :second)
    assert {:ok, :stop_requested} = LeaseBoundary.enforce(session, past)
    refute_interrupt()

    send_frame(session, transport, item_started(file_change("fc-1", "inProgress")))
    refute_interrupt()

    {:ok, status} = Session.status(session)
    assert status.stop_requested == :safe_boundary

    send_frame(session, transport, item_completed(file_change("fc-1", "completed")))
    refute_interrupt()

    send_frame(session, transport, delta("done"))
    assert_interrupt()
    refute_interrupt()
  end

  test "commentary start alone does not release; a tool after commentary still blocks" do
    {session, transport} = start_session()

    send_frame(session, transport, item_started(command("exec-1", "1031")))
    assert {:ok, :stop_requested} = Session.request_safe_stop(session)

    send_frame(session, transport, item_completed(command_done("exec-1", "1031")))
    refute_interrupt()

    # Commentary routinely precedes the next tool call in the same
    # response, so its START is not model-activity evidence.
    send_frame(session, transport, item_started(message_started("msg-1")))
    refute_interrupt()

    send_frame(session, transport, item_started(command("exec-2", "1032")))
    refute_interrupt()

    send_frame(session, transport, item_completed(command_done("exec-2", "1032")))
    refute_interrupt()

    send_frame(session, transport, delta("done"))
    assert_interrupt()
  end

  test "safe cancel defers like safe stop; immediate cancel interrupts at once" do
    {session, transport} = start_session()

    send_frame(session, transport, item_started(command("exec-1", "1041")))
    assert {:ok, :cancelled} = Session.cancel(session, %{boundary: :safe})
    refute_interrupt()

    send_frame(session, transport, item_completed(command_done("exec-1", "1041")))
    refute_interrupt()

    send_frame(session, transport, delta("done"))
    assert_interrupt()

    # A fresh turn episode: immediate cancel still terminates now.
    {session2, transport2} = start_session()
    send_frame(session2, transport2, item_started(command("exec-2", "1042")))
    assert {:ok, :cancelled} = Session.cancel(session2, %{})
    assert_receive {:sent_rpc, %{"method" => "turn/interrupt"}}
  end

  # Documentation (passes on the pre-fix commits too): the immediate path
  # is unchanged by this slice — interrupt plus whole-group reap, proved
  # here against a real owned process group, not just the RPC.
  test "immediate cancel reaps the whole owned process group" do
    {:ok, runner} = PortRunner.spawn(["sleep", "30"])
    on_exit(fn -> PortRunner.killpg_id(runner.pgid, "KILL") end)

    {session, transport} = start_session(os_pid_override: runner.pgid)
    send_frame(session, transport, item_started(command("exec-9", "1099")))

    assert PortRunner.alive_id?(runner.pgid)

    assert {:ok, :cancelled} = Session.cancel(session, %{})
    assert_receive {:sent_rpc, %{"method" => "turn/interrupt"}}

    refute PortRunner.alive_id?(runner.pgid)
  end

  test "without a pending stop, deltas and completions never interrupt" do
    {session, transport} = start_session()

    send_frame(session, transport, item_started(command("exec-1", "1051")))
    send_frame(session, transport, item_completed(command_done("exec-1", "1051")))
    send_frame(session, transport, item_completed(message_done("msg-1")))
    send_frame(session, transport, delta("done"))
    refute_interrupt()

    {:ok, status} = Session.status(session)
    assert status.stop_requested == nil
  end

  test "natural terminal resolves a pending stop with no interrupt" do
    {session, transport} = start_session()

    send_frame(session, transport, item_started(command("exec-1", "1061")))
    assert {:ok, :stop_requested} = Session.request_safe_stop(session)

    send_frame(session, transport, turn_completed("interrupted"))
    refute_interrupt()

    {:ok, status} = Session.status(session)
    assert status.status == :interrupted
    assert status.stop_requested == nil
  end

  test "idle stop pends; the first model activity releases it exactly once" do
    {session, transport} = start_session()

    # No tool has run, but a request can still interleave with a start
    # already in transit — so even the idle request only pends.
    assert {:ok, :stop_requested} = Session.request_safe_stop(session)
    refute_interrupt()

    {:ok, status} = Session.status(session)
    assert status.stop_requested == :safe_boundary

    send_frame(session, transport, delta("working"))
    assert_interrupt()

    assert {:ok, :stop_requested} = Session.request_safe_stop(session)
    refute_interrupt()

    # Later tools and evidence in the same turn send nothing more.
    send_frame(session, transport, item_started(command("exec-1", "1071")))
    send_frame(session, transport, item_completed(command_done("exec-1", "1071")))
    send_frame(session, transport, delta("more"))
    refute_interrupt()
  end
end
