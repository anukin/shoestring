defmodule Shoestring.Harness.ClaudeHeadless.Transport do
  @moduledoc """
  Production stdio transport for one-shot
  `claude --print --verbose --output-format stream-json` runs.

  How it differs from the Codex transports (deliberate, evidence-backed):

  - One-shot, not persistent: the process is spawned with its final argv,
    streams JSONL on stdout, exits, and is reaped. There is no stdin
    protocol — stdin is closed (`dup2(/dev/null)`) because a headless run
    must never block on an unread stdin pipe (PortRunner wave-0 finding).
  - stdout stays pure JSONL: unlike `Shoestring.Elves.PortRunner`, stderr
    is NOT merged into the stream (merging would corrupt line parsing).
    The child's stderr inherits the BEAM's stderr so diagnostics stay
    visible in host logs; the exit status arrives via `:exit_status`.
  - Process-group ownership: the child is launched through the same
    `python3` `setsid` wrapper PortRunner uses, so pid == pgid and
    cancellation can `killpg` the whole group (Claude has no in-band
    interrupt equivalent to Codex `turn/interrupt` — cancellation is
    process-kill only).

  Owner protocol (mirrors the `codex_transport_*` naming):

  - `{:claude_transport_connected, pid}` — process spawned.
  - `{:claude_transport_frame, pid, line}` — one stdout line.
  - `{:claude_transport_error, pid, :oversized_frame}` — a line exceeded
    `max_frame_size`; the run fails closed upstream.
  - `{:claude_transport_closed, pid, reason}` — process exited
    (`{:exit_status, code}`) or the port died.
  """

  use GenServer
  require Logger

  @default_command "claude"
  @default_max_frame_size 262_144
  @default_kill_grace_ms 2_000
  @default_reap_timeout_ms 5_000

  # Same shape as PortRunner's wrapper: setsid (tolerating EPERM when the
  # OTP runtime already detached the child), stdin from /dev/null, exec.
  @setsid_wrapper "import os, sys\n" <>
                    "try:\n" <>
                    "    os.setsid()\n" <>
                    "except PermissionError:\n" <>
                    "    pass\n" <>
                    "fd = os.open(os.devnull, os.O_RDONLY)\n" <>
                    "os.dup2(fd, 0)\n" <>
                    "os.execvp(sys.argv[1], sys.argv[1:])\n"

  @doc """
  Starts the transport and spawns the child process.

  ## Options

    * `:owner` — PID receiving transport messages (required).
    * `:command` — executable name or path (default `"claude"`).
    * `:executable` — explicit resolved path (skips `System.find_executable/1`).
    * `:args` — argv tail (default `[]`).
    * `:cd` — working directory for the child. There is no `-C/--cd` flag
      on the CLI, so the working directory is pinned via the spawned
      process's cwd. Must be an existing directory; anything else fails
      closed with `{:error, {:invalid_workdir, dir}}`.
    * `:env` — explicit `[{binary, binary}]` environment overrides.
    * `:max_frame_size` — maximum stdout line size in bytes (default
      `262_144`). Oversized lines fail closed, never silently truncated.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Returns the child OS pid (== pgid under the setsid wrapper), or nil."
  def os_pid(pid) when is_pid(pid) do
    GenServer.call(pid, :os_pid)
  catch
    :exit, _ -> nil
  end

  @doc "Closes the port without signalling (the child is already gone)."
  def close(pid) when is_pid(pid) do
    GenServer.call(pid, :close)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Bounded TERM → KILL escalation against the whole owned process group,
  then closes the port. Safe to call twice. Refuses anything that is not
  a plausible owned pgid (never the BEAM's own group).
  """
  def terminate_group(pid, opts \\ []) when is_pid(pid) do
    GenServer.call(pid, {:terminate_group, opts}, 30_000)
  catch
    :exit, _ -> {:error, :transport_down}
  end

  # --- GenServer Callbacks ---

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    owner = Keyword.fetch!(opts, :owner)
    command = Keyword.get(opts, :command, @default_command)
    args = Keyword.get(opts, :args, [])
    max_frame_size = Keyword.get(opts, :max_frame_size, @default_max_frame_size)
    env = Keyword.get(opts, :env, [])

    with {:ok, exec_path} <- resolve_executable(opts, command),
         {:ok, cd_opt} <- validate_cd(Keyword.get(opts, :cd)),
         {:ok, launch} <- wrap_argv(exec_path, args) do
      {launch_exe, launch_args} = launch

      port_opts =
        [
          :binary,
          :use_stdio,
          :exit_status,
          {:line, max_frame_size},
          {:args, Enum.map(launch_args, &to_charlist/1)},
          {:env, port_env(env)}
        ] ++ cd_opt

      try do
        port = Port.open({:spawn_executable, to_charlist(launch_exe)}, port_opts)

        case Port.info(port, :os_pid) do
          {:os_pid, os_pid} when is_integer(os_pid) and os_pid > 1 ->
            case verify_group_leader(os_pid) do
              :ok ->
                send(owner, {:claude_transport_connected, self()})

                {:ok,
                 %{
                   port: port,
                   owner: owner,
                   os_pid: os_pid,
                   max_frame_size: max_frame_size,
                   discarding_oversized: false,
                   closed: false
                 }}

              {:error, reason} ->
                # `ps` cannot see the pid. Re-read driver state to
                # distinguish "fast child died during ps" (its
                # exit_status is already queued or imminently so — proceed
                # without touching the mailbox, preserving driver order)
                # from "live child ps cannot verify" (fail closed).
                case Port.info(port, :os_pid) do
                  nil ->
                    already_exited(port, owner, max_frame_size)

                  _ ->
                    safe_close_port(port)
                    {:stop, reason}
                end
            end

          _ ->
            # No OS pid: the child already exited before it could be
            # observed (fast failure under scheduling pressure — VERIFIED
            # intermittent). Its stdout (if any) and exit_status are
            # already queued in order behind this point in the mailbox,
            # so proceeding lets them drive closure deterministically
            # instead of crashing the spawn.
            already_exited(port, owner, max_frame_size)
        end
      rescue
        error -> {:stop, {:port_open_failed, error}}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:os_pid, _from, state) do
    {:reply, state.os_pid, state}
  end

  def handle_call(:close, _from, state) do
    send(state.owner, {:claude_transport_closed, self(), :normal})
    safe_close_port(state.port)
    {:stop, :normal, :ok, %{state | closed: true}}
  end

  def handle_call({:terminate_group, opts}, _from, state) do
    grace_ms = Keyword.get(opts, :kill_grace_ms, @default_kill_grace_ms)
    reap_ms = Keyword.get(opts, :reap_timeout_ms, @default_reap_timeout_ms)

    result =
      if group_alive?(state.os_pid) do
        _ = killpg(state.os_pid, "TERM")

        case await_exit(state.port, grace_ms) do
          {:ok, _status} ->
            :exited

          {:timeout, _port} ->
            _ = killpg(state.os_pid, "KILL")

            case await_exit(state.port, reap_ms) do
              {:ok, _status} -> :killed
              {:timeout, _port} -> :reap_timeout
            end
        end
      else
        :already_exited
      end

    safe_close_port(state.port)

    reply =
      case result do
        :reap_timeout -> {:error, :reap_timeout}
        status -> {:ok, status}
      end

    {:stop, :normal, reply, %{state | closed: true}}
  end

  @impl GenServer
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    if state.discarding_oversized do
      send(state.owner, {:claude_transport_error, self(), :oversized_frame})
      {:noreply, %{state | discarding_oversized: false}}
    else
      send(state.owner, {:claude_transport_frame, self(), String.trim_trailing(line, "\r")})
      {:noreply, state}
    end
  end

  def handle_info({port, {:data, {:noeol, _chunk}}}, %{port: port} = state) do
    # Line exceeded max_frame_size.
    {:noreply, %{state | discarding_oversized: true}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    unless state.closed do
      send(state.owner, {:claude_transport_closed, self(), {:exit_status, status}})
    end

    {:stop, :normal, %{state | closed: true}}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    unless state.closed do
      # The driver reports the child exit before tearing the port down,
      # but under scheduling pressure this EXIT can be processed first
      # while the exit_status is already queued behind it. Prefer the
      # real exit code whenever it is already here — consumed and acted
      # on inline, never re-queued (re-queueing would invert the order).
      # Nothing is waited for: if no exit is queued, report the reason.
      case take_queued_exit(port) do
        {:exited, status} ->
          send(state.owner, {:claude_transport_closed, self(), {:exit_status, status}})

        :running ->
          send(state.owner, {:claude_transport_closed, self(), reason})
      end
    end

    {:stop, :normal, %{state | closed: true}}
  end

  def handle_info({:EXIT, owner, reason}, %{owner: owner} = state) do
    safe_close_port(state.port)
    {:stop, reason, state}
  end

  def handle_info(_other, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if state && Map.has_key?(state, :port) do
      safe_close_port(state.port)
    end

    :ok
  end

  # --- Spawn helpers ---

  # The child is already gone: start in a state with no owned group.
  # Queued stdout lines and the exit_status still arrive in order and
  # drive closure through the normal handle_info path. Termination
  # against a nil pgid is a no-op (:already_exited), so kill-based
  # cancel stays safe.
  defp already_exited(port, owner, max_frame_size) do
    send(owner, {:claude_transport_connected, self()})

    {:ok,
     %{
       port: port,
       owner: owner,
       os_pid: nil,
       max_frame_size: max_frame_size,
       discarding_oversized: false,
       closed: false
     }}
  end

  # Non-blocking mailbox scan for an already-delivered exit_status from
  # our own port. `after 0` never waits — it only observes a signal that
  # has already arrived. The exit is consumed and returned for immediate
  # inline handling; it is NEVER re-queued, because re-queueing would move
  # it behind a concurrently queued port EXIT and invert driver order.
  defp take_queued_exit(port) do
    receive do
      {^port, {:exit_status, status}} -> {:exited, status}
    after
      0 -> :running
    end
  end

  defp resolve_executable(opts, command) do
    case Keyword.get(opts, :executable) do
      nil ->
        case System.find_executable(command) do
          nil -> {:error, :executable_not_found}
          path -> {:ok, path}
        end

      path when is_binary(path) ->
        if File.regular?(path) or not String.contains?(path, "/") do
          {:ok, path}
        else
          {:error, {:executable_not_found, path}}
        end
    end
  end

  defp validate_cd(nil), do: {:ok, []}

  defp validate_cd(dir) when is_binary(dir) do
    cond do
      dir == "" or String.contains?(dir, <<0>>) -> {:error, {:invalid_workdir, dir}}
      File.dir?(dir) -> {:ok, [{:cd, to_charlist(dir)}]}
      true -> {:error, {:invalid_workdir, dir}}
    end
  end

  defp validate_cd(other), do: {:error, {:invalid_workdir, other}}

  defp wrap_argv(executable, args) do
    case System.find_executable("python3") do
      nil ->
        {:error, :setsid_unavailable}

      python3 ->
        {:ok, {python3, ["-c", @setsid_wrapper, executable | args]}}
    end
  end

  defp port_env(env) do
    Enum.map(env, fn
      {key, value} when is_binary(key) and is_binary(value) ->
        {to_charlist(key), to_charlist(value)}

      entry ->
        raise ArgumentError, "port env must be [{binary, binary}], got: #{inspect(entry)}"
    end)
  end

  # Fails closed unless the spawned pid leads its own process group —
  # without leadership, killpg could signal a group we do not own.
  defp verify_group_leader(os_pid) do
    case System.cmd("ps", ["-o", "pgid=", "-p", to_string(os_pid)], stderr_to_stdout: true) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {^os_pid, _rest} -> :ok
          _other -> {:error, :not_group_leader}
        end

      {_output, _status} ->
        {:error, :group_leader_unverifiable}
    end
  rescue
    _error -> {:error, :group_leader_unverifiable}
  end

  # --- Kill helpers ---

  defp group_alive?(pgid) when is_integer(pgid) and pgid > 1 do
    case System.cmd("kill", ["-0", "-#{pgid}"], stderr_to_stdout: true) do
      {_out, 0} -> true
      {_out, _status} -> false
    end
  rescue
    _ -> false
  end

  defp group_alive?(_pgid), do: false

  defp killpg(pgid, signal) when is_integer(pgid) and pgid > 1 and signal in ["TERM", "KILL"] do
    # Never signal the BEAM's own process group.
    if pgid == beam_os_pid() do
      {:error, :refuse_own_process_group}
    else
      case System.cmd("kill", ["-#{signal}", "-#{pgid}"], stderr_to_stdout: true) do
        {_out, 0} -> :ok
        {out, _status} -> {:error, {:killpg_failed, String.trim(out)}}
      end
    end
  end

  defp beam_os_pid do
    case Integer.parse(to_string(:os.getpid())) do
      {pid, _rest} -> pid
      :error -> -1
    end
  end

  defp await_exit(port, timeout_ms) do
    receive do
      {^port, {:exit_status, status}} -> {:ok, status}
    after
      timeout_ms -> {:timeout, port}
    end
  end

  defp safe_close_port(port) when is_port(port) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    end
  end

  defp safe_close_port(_), do: :ok
end
