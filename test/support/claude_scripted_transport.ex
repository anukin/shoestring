defmodule Shoestring.Harness.ClaudeScriptedTransport do
  @moduledoc """
  Scripted transport double for Claude headless sessions (mirrors the
  Codex `ScriptedTransport` pattern).

  Drives the session through the same owner-message protocol as the
  production `ClaudeHeadless.Transport` (`{:claude_transport_frame, pid,
  line}` / `{:claude_transport_closed, pid, reason}`), replaying canned
  JSONL lines on demand so tests control exactly which frames the session
  has observed at each assertion point.
  """

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def os_pid(pid) when is_pid(pid) do
    GenServer.call(pid, :os_pid)
  end

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
       terminated: false,
       test_pid: Keyword.get(opts, :test_pid)
     }}
  end

  @impl GenServer
  def handle_call(:os_pid, {caller, _}, state) do
    {:reply, 77_777, maybe_adopt(state, caller)}
  end

  @impl GenServer
  def handle_call(:emit, _from, %{lines: [line | rest]} = state) do
    if state.owner, do: send(state.owner, {:claude_transport_frame, self(), line})
    {:reply, :ok, %{state | lines: rest}}
  end

  def handle_call(:emit, _from, state) do
    if state.owner,
      do: send(state.owner, {:claude_transport_closed, self(), {:exit_status, state.exit_status}})

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

  def handle_call({:set_test_pid, pid}, _from, state) when is_pid(pid) do
    {:reply, :ok, %{state | test_pid: pid}}
  end

  # Adopts the first caller as owner when none was configured, and tells
  # the test process which session booted. This is the deterministic sync
  # point for adapter-level tests: the session always calls os_pid/1 while
  # booting, so the test learns the session pid with a plain receive —
  # no polling, no sleeps — before emitting any frames.
  defp maybe_adopt(%{owner: nil, test_pid: test_pid} = state, caller)
       when is_pid(caller) do
    if is_pid(test_pid), do: send(test_pid, {:claude_scripted_adopted, caller})
    %{state | owner: caller}
  end

  defp maybe_adopt(state, _caller), do: state
end
