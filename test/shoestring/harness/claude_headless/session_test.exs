defmodule Shoestring.Harness.ClaudeHeadless.SessionTest do
  @moduledoc """
  Session tests for the Claude headless one-shot adapter.

  The `ScriptedTransport` double mirrors the Codex `ScriptedTransport`
  pattern: the session drives it through the same owner-message protocol
  (`{:claude_transport_frame, pid, line}` /
  `{:claude_transport_closed, pid, reason}`), so spawn -> parse ->
  normalize -> terminal is covered end to end — not just the normalizer
  in isolation. Two tests go further and spawn a REAL OS process through
  the production `Transport` with trivial local commands (`cat`, `false`),
  so the live path is wired, not simulated.
  """

  use ExUnit.Case, async: true

  alias Shoestring.Harness.ClaudeHeadless.{Session, Transport}
  alias Shoestring.Harness.{RunIdentity, RunRequest}

  @fixture_dir "plans/evidence/04-single-elf/fixtures/claude"

  defmodule ScriptedTransport do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    def os_pid(_pid), do: 77_777

    def terminate_group(pid, _opts \\ []) do
      GenServer.call(pid, :terminate_group)
    end

    def emit(pid) do
      GenServer.call(pid, :emit)
    end

    def replay_all(pid) do
      GenServer.call(pid, :replay_all)
    end

    @impl GenServer
    def init(opts) do
      {:ok,
       %{
         owner: Keyword.get(opts, :owner),
         lines: Keyword.get(opts, :lines, []),
         exit_status: Keyword.get(opts, :exit_status, 0),
         terminated: false
       }}
    end

    @impl GenServer
    def handle_call(:emit, _from, %{lines: [line | rest]} = state) do
      if state.owner, do: send(state.owner, {:claude_transport_frame, self(), line})
      {:reply, :ok, %{state | lines: rest}}
    end

    def handle_call(:emit, _from, state) do
      if state.owner,
        do:
          send(state.owner, {:claude_transport_closed, self(), {:exit_status, state.exit_status}})

      {:reply, :ok, state}
    end

    def handle_call(:replay_all, _from, state) do
      if state.owner do
        for line <- state.lines do
          send(state.owner, {:claude_transport_frame, self(), line})
        end

        send(state.owner, {:claude_transport_closed, self(), {:exit_status, state.exit_status}})
      end

      {:reply, :ok, %{state | lines: []}}
    end

    def handle_call(:terminate_group, _from, state) do
      if state.owner do
        send(state.owner, {:claude_transport_closed, self(), {:exit_status, 143}})
      end

      {:reply, {:ok, :killed}, %{state | terminated: true, lines: []}}
    end

    def handle_call(:was_terminated, _from, state) do
      {:reply, state.terminated, state}
    end
  end

  defp fixture_lines(name) do
    Path.join(@fixture_dir, name)
    |> File.read!()
    |> String.split("\n", trim: true)
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

  defp start_scripted_session(lines, opts \\ []) do
    req = make_test_run_request()

    {:ok, transport} =
      start_supervised(
        {ScriptedTransport, [owner: nil, lines: lines] ++ Keyword.take(opts, [:exit_status])}
      )

    session =
      start_supervised!(
        {Session,
         [
           run_request: req,
           run_id: req.dispatch_id,
           transport_pid: transport,
           transport: ScriptedTransport,
           owner: self()
         ]}
      )

    :sys.replace_state(transport, fn state -> %{state | owner: session} end)
    {transport, session}
  end

  describe "scripted full-path replay (spawn -> parse -> normalize -> terminal)" do
    test "tool-exec fixture terminates completed with correlated command pairs" do
      {transport, session} = start_scripted_session(fixture_lines("stream-json-tool-exec.jsonl"))

      :ok = ScriptedTransport.replay_all(transport)
      _ = :sys.get_state(session)

      {:ok, summary} = Session.await_terminal(session, 5_000)
      assert summary.status == :completed
      assert summary.provider_session_id == "aaaaaaaa-0000-4000-a000-000000000002"
      assert summary.in_flight == []
      assert summary.exit_status == 0

      {:ok, events} = Session.stream_events(session)

      assert Enum.map(events, & &1.kind) == [
               :lifecycle,
               :lifecycle,
               :command,
               :command,
               :command,
               :command,
               :output,
               :result
             ]

      {:ok, identity} = Session.get_run_identity(session)
      assert %RunIdentity{} = identity
      assert identity.provider_session_id == "aaaaaaaa-0000-4000-a000-000000000002"
      assert identity.harness_id == "claude_headless_stream_json"
    end

    test "auth-failure fixture terminates failed with a task_failed error, never quota_refused" do
      {transport, session} =
        start_scripted_session(fixture_lines("stream-json-auth-failure.jsonl"))

      :ok = ScriptedTransport.replay_all(transport)
      _ = :sys.get_state(session)

      {:ok, summary} = Session.await_terminal(session, 5_000)
      assert summary.status == :failed
      assert {:error, %{category: :task_failed, code: "api_error"}} = summary.terminal_result

      {:ok, events} = Session.stream_events(session)
      assert Enum.any?(events, &(&1.kind == :error))
      refute Enum.any?(events, &(&1.kind == :result))
    end

    test "malformed lines are counted and ignored; the session survives" do
      lines = ["not json at all", "{unterminated"] ++ fixture_lines("stream-json-tool-exec.jsonl")
      {transport, session} = start_scripted_session(lines)

      :ok = ScriptedTransport.replay_all(transport)
      _ = :sys.get_state(session)

      {:ok, summary} = Session.await_terminal(session, 5_000)
      assert summary.status == :completed
      assert summary.malformed_lines == 2

      {:ok, events} = Session.stream_events(session)
      assert length(events) == 8
    end

    test "exit without any result frame fails closed, never fabricates completion" do
      {transport, session} = start_scripted_session([], exit_status: 0)

      :ok = ScriptedTransport.emit(transport)
      _ = :sys.get_state(session)

      {:ok, summary} = Session.await_terminal(session, 5_000)
      assert summary.status == :failed
      assert {:error, %{code: "missing_result_frame"}} = summary.terminal_result
    end

    test "nonzero exit without a result frame is a transport error" do
      {transport, session} = start_scripted_session([], exit_status: 1)

      :ok = ScriptedTransport.emit(transport)
      _ = :sys.get_state(session)

      {:ok, summary} = Session.await_terminal(session, 5_000)
      assert summary.status == :failed
      assert {:error, %{code: "nonzero_exit"}} = summary.terminal_result
    end
  end

  describe "kill-only cancellation" do
    test "immediate cancel kills the group; repeat cancel is idempotent" do
      lines = fixture_lines("stream-json-tool-exec.jsonl")
      {transport, session} = start_scripted_session(lines)

      :ok = ScriptedTransport.emit(transport)
      :ok = ScriptedTransport.emit(transport)
      :ok = ScriptedTransport.emit(transport)
      _ = :sys.get_state(session)

      {:ok, status} = Session.status(session)
      assert length(status.in_flight) == 1

      assert {:ok, :cancelled} = Session.cancel(session)
      _ = :sys.get_state(session)

      {:ok, status} = Session.status(session)
      assert status.status == :cancelled
      assert GenServer.call(transport, :was_terminated) == true

      # Terminal idempotency.
      assert {:ok, :cancelled} = Session.cancel(session)
    end

    test "safe-boundary cancel defers the kill until the in-flight set drains" do
      lines = fixture_lines("stream-json-tool-exec.jsonl")
      {transport, session} = start_scripted_session(lines)

      # init + rate_limit + 2 STARTs: two tools in flight.
      for _ <- 1..4, do: :ok = ScriptedTransport.emit(transport)
      _ = :sys.get_state(session)

      {:ok, status} = Session.status(session)
      assert length(status.in_flight) == 2

      assert {:ok, :cancelled} = Session.cancel(session, %{boundary: :safe})
      _ = :sys.get_state(session)

      # Deferred: still running, nothing killed yet.
      {:ok, status} = Session.status(session)
      assert status.status == :running
      assert status.stop_requested == :safe_boundary
      assert GenServer.call(transport, :was_terminated) == false

      # First END drains one tool — still deferred.
      :ok = ScriptedTransport.emit(transport)
      _ = :sys.get_state(session)
      assert GenServer.call(transport, :was_terminated) == false

      # Second END drains the set — the group is reaped before the next tool.
      :ok = ScriptedTransport.emit(transport)
      _ = :sys.get_state(session)

      assert GenServer.call(transport, :was_terminated) == true
      {:ok, status} = Session.status(session)
      assert status.status == :cancelled

      # Late frames (final text + result) are ignored past the terminal state.
      :ok = ScriptedTransport.replay_all(transport)
      _ = :sys.get_state(session)
      {:ok, status} = Session.status(session)
      assert status.status == :cancelled
    end
  end

  describe "live transport end to end (real OS process, trivial local commands)" do
    test "cat of the tool-exec fixture streams 8 normalized events to completed" do
      cat = System.find_executable("cat")
      assert is_binary(cat), "cat must be on PATH for the hermetic live test"

      req = make_test_run_request()
      fixture = Path.join(@fixture_dir, "stream-json-tool-exec.jsonl") |> Path.expand()

      session =
        start_supervised!(
          {Session,
           [
             run_request: req,
             run_id: req.dispatch_id,
             transport: Transport,
             command: cat,
             executable: cat,
             args: [fixture],
             owner: self()
           ]}
        )

      {:ok, summary} = Session.await_terminal(session, 15_000)
      assert summary.status == :completed
      assert summary.provider_session_id == "aaaaaaaa-0000-4000-a000-000000000002"

      {:ok, events} = Session.stream_events(session)
      assert length(events) == 8
      assert Enum.any?(events, &(&1.kind == :result))
    end

    test "a failing command with no result frame fails closed" do
      false_bin = System.find_executable("false")
      assert is_binary(false_bin), "false must be on PATH for the hermetic live test"

      req = make_test_run_request()

      session =
        start_supervised!(
          {Session,
           [
             run_request: req,
             run_id: req.dispatch_id,
             transport: Transport,
             command: false_bin,
             executable: false_bin,
             args: [],
             owner: self()
           ]}
        )

      {:ok, summary} = Session.await_terminal(session, 15_000)
      assert summary.status == :failed
      assert {:error, %{code: "nonzero_exit"}} = summary.terminal_result
    end
  end
end
