defmodule Shoestring.Harness.CodexAppServer.SessionSafeBoundaryTest do
  @moduledoc """
  Hermetic regression tests for terminal-only lease safe stops: a pending
  safe stop or safe cancel must NEVER send `turn/interrupt` — not on
  request, delta, reasoning activity, completion, timeout, quiet, or
  anything else — and resolves solely at the authoritative turn outcome.

  Each test drives a real `Session` with scripted provider frames through a
  recording transport double — never a provider CLI, never the network.

  Locking note (standing contract): on the pre-fix commits (`1566acd`
  single slot sending on any completion; `e675c3b` sending on completion,
  evidence, and request-time) every test asserting "no interrupt yet"
  fails behaviourally — the interrupt arrives mid-stream. The
  immediate-cancel tests are documentation: that distinct explicit path is
  unchanged and passes on both.
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

  defp refute_interrupt, do: refute_receive({:sent_rpc, %{"method" => "turn/interrupt"}})

  defp assert_terminal_resolution(session) do
    {:ok, status} = Session.status(session)
    assert status.stop_requested == nil
    assert status.status in [:completed, :interrupted, :failed]
  end

  test "reasoning activity beside an open command never interrupts; the outcome resolves" do
    {session, transport} = start_session()

    send_frame(session, transport, item_started(command("exec-1", "1001")))
    send_frame(session, transport, item_started(reasoning("r-1")))

    assert {:ok, :stop_requested} = Session.request_safe_stop(session)
    refute_interrupt()

    # The reasoning completion must not clear the open command, and no
    # frame class releases the stop.
    send_frame(session, transport, item_completed(reasoning("r-1")))
    refute_interrupt()

    send_frame(session, transport, item_completed(command_done("exec-1", "1001")))
    refute_interrupt()

    send_frame(session, transport, delta("more"))
    refute_interrupt()

    send_frame(session, transport, item_started(reasoning("r-2")))
    refute_interrupt()

    send_frame(session, transport, turn_completed("interrupted"))
    refute_interrupt()
    assert_terminal_resolution(session)
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
    refute_interrupt()

    send_frame(session, transport, turn_completed("completed"))
    refute_interrupt()
    assert_terminal_resolution(session)
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

    send_frame(session, transport, item_started(reasoning("r-1")))
    refute_interrupt()

    send_frame(session, transport, turn_completed("interrupted"))
    refute_interrupt()
    assert_terminal_resolution(session)
  end

  test "overlapping commands each hold the pending stop until the outcome" do
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
    refute_interrupt()

    send_frame(session, transport, turn_completed("interrupted"))
    refute_interrupt()
    assert_terminal_resolution(session)
  end

  test "file change plus reasoning: no frame class releases while the write is open" do
    {session, transport} = start_session()

    send_frame(session, transport, item_started(file_change("fc-1", "inProgress")))
    assert {:ok, :stop_requested} = Session.request_safe_stop(session)

    send_frame(session, transport, item_started(reasoning("r-1")))
    refute_interrupt()

    send_frame(session, transport, item_completed(reasoning("r-1")))
    refute_interrupt()

    send_frame(session, transport, item_completed(file_change("fc-1", "completed")))
    refute_interrupt()

    send_frame(session, transport, item_completed(message_done("msg-9")))
    refute_interrupt()

    send_frame(session, transport, delta("done"))
    refute_interrupt()

    send_frame(session, transport, turn_completed("interrupted"))
    refute_interrupt()
    assert_terminal_resolution(session)
  end

  test "unknown tool types fail conservatively until the outcome" do
    {session, transport} = start_session()

    send_frame(session, transport, item_started(unknown_tool("x-1")))
    assert {:ok, :stop_requested} = Session.request_safe_stop(session)

    # A message completing beside the unknown tool releases nothing.
    send_frame(session, transport, item_completed(message_done("msg-1")))
    refute_interrupt()

    send_frame(session, transport, item_completed(unknown_tool_done("x-1")))
    refute_interrupt()

    send_frame(session, transport, delta("done"))
    refute_interrupt()

    send_frame(session, transport, turn_completed("interrupted"))
    refute_interrupt()
    assert_terminal_resolution(session)
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
    assert_terminal_resolution(session)
  end

  # N4: a nil/missing item type opens conservatively in the session while
  # the Elf layer ignores it — and NEITHER layer acts early. Both fail
  # closed consistently: the stop resolves only at the outcome.
  test "nil and missing item types open conservatively and resolve only at the outcome" do
    {session, transport} = start_session()

    send_frame(session, transport, item_started(%{"type" => nil, "id" => "nil-1"}))
    send_frame(session, transport, item_started(%{"id" => "notype-1"}))

    {:ok, status} = Session.status(session)
    assert status.open_tool_count == 2

    assert {:ok, :stop_requested} = Session.request_safe_stop(session)
    refute_interrupt()

    send_frame(session, transport, delta("done"))
    refute_interrupt()

    send_frame(session, transport, turn_completed("interrupted"))
    refute_interrupt()
    assert_terminal_resolution(session)
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
    refute_interrupt()

    send_frame(session, transport, turn_completed("interrupted"))
    refute_interrupt()
    assert_terminal_resolution(session)
  end

  # LOCK (fails behaviourally on 1566acd and on e675c3b): the Elf-driven
  # shape from the committed trace (command end 141, bookkeeping 142-143,
  # fileChange start 144). The deadline stop is requested through the
  # Elf's own boundary module AFTER the command completed; the fileChange
  # starts while the request is pending. Neither the request nor any later
  # frame may send: the write must survive until the turn outcome, which
  # resolves the stop with no send.
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
    refute_interrupt()

    send_frame(session, transport, turn_completed("interrupted"))
    refute_interrupt()
    assert_terminal_resolution(session)
  end

  # LOCK (fails behaviourally on 1566acd and on e675c3b): the 139→140
  # shape from the committed trace
  # (normalized-codex-lease-stop-final.md). A message completion with an
  # empty open set must not release the stop — the provider routinely
  # starts the next tool immediately after completing commentary.
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

    # The next tool starts as part of the same model action; it must run
    # to its own outcome untouched.
    send_frame(session, transport, item_started(command("exec-2", "1014")))
    refute_interrupt()

    send_frame(session, transport, item_completed(command_done("exec-2", "1014")))
    refute_interrupt()

    send_frame(session, transport, turn_completed("interrupted"))
    refute_interrupt()
    assert_terminal_resolution(session)
  end

  test "commentary start alone does not release; a tool after commentary still blocks" do
    {session, transport} = start_session()

    send_frame(session, transport, item_started(command("exec-1", "1031")))
    assert {:ok, :stop_requested} = Session.request_safe_stop(session)

    send_frame(session, transport, item_completed(command_done("exec-1", "1031")))
    refute_interrupt()

    # Commentary routinely precedes the next tool call in the same
    # response; nothing about it releases the stop.
    send_frame(session, transport, item_started(message_started("msg-1")))
    refute_interrupt()

    send_frame(session, transport, item_started(command("exec-2", "1032")))
    refute_interrupt()

    send_frame(session, transport, item_completed(command_done("exec-2", "1032")))
    refute_interrupt()

    send_frame(session, transport, delta("done"))
    refute_interrupt()

    send_frame(session, transport, turn_completed("interrupted"))
    refute_interrupt()
    assert_terminal_resolution(session)
  end

  test "safe cancel defers like safe stop; immediate cancel interrupts at once" do
    {session, transport} = start_session()

    send_frame(session, transport, item_started(command("exec-1", "1041")))
    assert {:ok, :cancelled} = Session.cancel(session, %{boundary: :safe})
    refute_interrupt()

    send_frame(session, transport, item_completed(command_done("exec-1", "1041")))
    refute_interrupt()

    send_frame(session, transport, delta("done"))
    refute_interrupt()

    send_frame(session, transport, turn_completed("interrupted"))
    refute_interrupt()
    assert_terminal_resolution(session)

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

    send_frame(session, transport, turn_completed("completed"))
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
    assert_terminal_resolution(session)
  end

  test "idle stop pends until the turn outcome" do
    {session, transport} = start_session()

    # No tool has run, but a request can still interleave with a start
    # already in transit — so even the idle request only pends, and only
    # the authoritative outcome resolves it.
    assert {:ok, :stop_requested} = Session.request_safe_stop(session)
    refute_interrupt()

    {:ok, status} = Session.status(session)
    assert status.stop_requested == :safe_boundary

    send_frame(session, transport, delta("working"))
    refute_interrupt()

    send_frame(session, transport, turn_completed("interrupted"))
    refute_interrupt()
    assert_terminal_resolution(session)
  end
end
