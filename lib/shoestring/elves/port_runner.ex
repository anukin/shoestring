defmodule Shoestring.Elves.PortRunner do
  @moduledoc """
  Owns one external OS process group for an Elf run.

  ## Process-group ownership (wave-0 finding)

  Descendants of a harness process survive both signal delivery to the direct
  child and transport close: wave 0 proved live that a `sleep 45` grandchild
  was reparented to pid 1. The Elf must therefore own the process group id and
  `killpg` + reap, never just signal the direct child.

  Erlang ports give no native `setsid` support, so this module launches through
  the smallest reliable mechanism available in Elixir: a `python3` wrapper that
  calls `os.setsid()` (making the launched program a session/group leader, so
  its pid == its pgid), redirects stdin from `/dev/null`, and `exec`s the
  target argv. All cancellation then targets `-pgid` (the whole group) and
  reaps with a bounded TERM → KILL escalation.

  The OTP runtime's `erl_child_setup` also `setsid()`s every port child before
  `exec`, so the wrapper's own `setsid()` usually raises `EPERM`. The wrapper
  treats that as success (`EPERM` from `setsid` means the caller already leads
  its group, hence pid == pgid either way), and `spawn/2` additionally
  verifies leadership with `ps` and fails closed when it does not hold.

  ## Leadership handshake (why `spawn/2` waits for the child)

  "pid == pgid on arrival" is not true at the moment the BEAM learns the pid.
  In OTP 28 `erl_child_setup` reports the forked pid to the BEAM right after
  `fork()`; the child only calls `setsid()` after the BEAM acknowledges, just
  before `exec` (`erts/emulator/sys/unix/erl_child_setup.c`,
  `start_new_child/1`). A leadership check that runs as soon as the pid is
  known is therefore a race: a child the scheduler has not yet run still
  reports its parent's pgid, and the launch fails closed as
  `not_group_leader` for a perfectly good child.

  So the check is synchronised instead of hoped for. The wrapper, once it
  leads its group (it verifies `getpgid(0) == getpid()` itself), writes one
  line `#{"SHOESTRING-SETSID-READY <pid>"}` to stdout and blocks reading one
  byte of stdin. `spawn/2` waits (bounded by `:handshake_timeout_ms`,
  fail-closed) for that line, checks the pid it names, runs the `ps` check
  while the child is provably alive and leading its group, and only then
  writes the byte that lets the wrapper redirect stdin and `exec`. No target
  output can precede or mix with the handshake line, because the target has
  not been executed yet. A wrapper that sees EOF instead of the byte exits
  without executing anything.

  ## Honest limitations (not terminal-grade control)

    * Requires `python3` on `PATH` at spawn time (also documented in
      `README.md` and `AGENTS.md`). Without it, spawn fails closed
      (`{:error, :setsid_unavailable}`, surfaced to the trajectory as
      `error_code: "setsid_unavailable"`) unless the caller explicitly passes
      `allow_no_setsid: true`, in which case only the direct child is
      signalled and descendants may survive — the return documents the
      degraded mode. Full PTY/process-group hardening is explicitly owned by
      iteration 9; this module does not claim it. The recommended replacement
      is a ~20-line compiled C shim in `c_src/` (or `:erlexec`): the
      interpreter costs roughly 30-50ms per spawn and the host `PYTHONPATH`
      leaks into the launch environment.
    * `kill -0 -pgid` proves the group exists, not that every descendant is
      healthy; a group can linger while its useful work is done (see
      `Shoestring.Elves.Staleness` — that observation is evidence, never an
      automatic kill).
    * Orphaned groups after a BEAM crash cannot be `waitpid(2)`-reaped by a
      restarted VM (they belong to init); recovery observes and terminates
      them but cannot reap their exit status.
    * Port `env:` extends the BEAM environment with the explicit overrides —
      it does not wipe it. "Controlled" means: argv arrays only (never shell
      strings, so no interpolation/injection surface) plus an explicit env
      list; callers must pass only the variables the harness needs.

  ## stdin control (wave-0 finding)

  `codex exec` hangs forever with zero output when stdin is left open as a
  pipe. The wrapper therefore `dup2`s `/dev/null` over fd 0 before `exec`, so
  the harness can never block on an unread stdin pipe. That close is
  deliberate, not incidental.

  ## Output bounds (fail-closed, never silent truncation)

  Raw bytes accumulate only up to `max_output_bytes:` (default 262 144). Past
  the cap the runner reports `{:error, :output_overflow}` and the Elf fails
  the run explicitly with a `log_overflow` classification — oversized output
  is the Log flood eval and must never be silently discarded the way a
  line-capped transport would.
  """

  @default_max_output_bytes 262_144
  @default_kill_grace_ms 5_000
  @default_reap_timeout_ms 5_000

  # `setsid` raises `PermissionError` when the child already leads its group
  # (the OTP runtime detaches port children into their own session, so this
  # is the common case, not an error): either way pid == pgid afterwards,
  # which `spawn/2` verifies with `ps` before returning.
  #
  # Then it announces leadership and waits for the go byte before redirecting
  # stdin and executing: see "Leadership handshake" in the moduledoc.
  @handshake_prefix "SHOESTRING-SETSID-READY "
  @setsid_wrapper "import os, sys\n" <>
                    "try:\n" <>
                    "    os.setsid()\n" <>
                    "except PermissionError:\n" <>
                    "    pass\n" <>
                    "if os.getpgid(0) != os.getpid():\n" <>
                    "    sys.exit(125)\n" <>
                    "os.write(1, b'#{@handshake_prefix}%d\\n' % os.getpid())\n" <>
                    "if os.read(0, 1) != b'\\n':\n" <>
                    "    sys.exit(125)\n" <>
                    "fd = os.open(os.devnull, os.O_RDONLY)\n" <>
                    "os.dup2(fd, 0)\n" <>
                    "os.execvp(sys.argv[1], sys.argv[1:])\n"
  @default_handshake_timeout_ms 15_000

  @doc false
  # The wrapper and its handshake line, shared with the Claude headless
  # transport so the two launchers cannot drift apart.
  def setsid_wrapper, do: @setsid_wrapper

  @doc false
  def handshake_prefix, do: @handshake_prefix

  @doc false
  def default_handshake_timeout_ms, do: @default_handshake_timeout_ms

  @type t :: %__MODULE__{
          port: port() | nil,
          os_pid: pos_integer() | nil,
          pgid: pos_integer() | nil,
          argv: [binary()],
          setsid: boolean(),
          output_bytes: non_neg_integer(),
          max_output_bytes: pos_integer(),
          overflowed?: boolean()
        }

  defstruct [
    :port,
    :os_pid,
    :pgid,
    argv: [],
    setsid: true,
    output_bytes: 0,
    max_output_bytes: @default_max_output_bytes,
    overflowed?: false
  ]

  @doc "Default raw-output byte cap before fail-closed overflow."
  @spec default_max_output_bytes() :: pos_integer()
  def default_max_output_bytes, do: @default_max_output_bytes

  @doc """
  Spawns `argv` (a non-empty list of binaries, head = executable) under a new
  process group and returns the handle. Never builds a shell command string.

  ## Options

    * `:env` — explicit `[{binary, binary}]` environment overrides.
    * `:cd` — working directory for the child (required for WP-A worktree
      isolation and WP-C adapters, which must run inside the run's worktree).
      Must be an existing directory; anything else fails closed with
      `{:error, {:invalid_workdir, dir}}`.
    * `:setsid` / `:allow_no_setsid` — process-group leadership control.
    * `:max_output_bytes` — raw-output cap before fail-closed overflow.
  """
  @spec spawn([binary()], keyword()) :: {:ok, t()} | {:error, term()}
  def spawn(argv, opts \\ []) do
    with {:ok, executable, exec_args} <- validate_argv(argv),
         {:ok, {launch_exe, launch_args}, wrapped?} <- wrap_argv(executable, exec_args, opts),
         {:ok, cd_opt} <- validate_cd(opts),
         {:ok, port} <- open_port(launch_exe, launch_args, opts, cd_opt) do
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} when is_integer(os_pid) and os_pid > 0 ->
          case verify_launched_leader(port, os_pid, wrapped?, opts) do
            :ok ->
              {:ok,
               %__MODULE__{
                 port: port,
                 os_pid: os_pid,
                 pgid: os_pid,
                 argv: argv,
                 setsid: setsid?(opts),
                 max_output_bytes: Keyword.get(opts, :max_output_bytes, @default_max_output_bytes)
               }}

            {:error, _reason} = error ->
              discard_port(port)
              error
          end

        _other ->
          discard_port(port)
          {:error, :os_pid_unavailable}
      end
    end
  end

  @doc """
  Sends `signal` (`"TERM"` or `"KILL"`) to the whole owned process group.
  Refuses to signal anything that is not a plausible owned pgid.
  """
  @spec killpg(t(), String.t()) :: :ok | {:error, term()}
  def killpg(%__MODULE__{pgid: pgid}, signal) when signal in ["TERM", "KILL"] do
    killpg_id(pgid, signal)
  end

  @doc "Sends `signal` to a raw pgid (used by recovery without a live handle)."
  @spec killpg_id(term(), String.t()) :: :ok | {:error, term()}
  def killpg_id(pgid, signal) when signal in ["TERM", "KILL"] do
    with :ok <- validate_pgid(pgid) do
      case System.cmd("kill", ["-#{signal}", "-#{pgid}"], stderr_to_stdout: true) do
        {_out, 0} -> :ok
        {out, _status} -> {:error, {:killpg_failed, String.trim(out)}}
      end
    end
  end

  @doc "Returns true while the process group still exists (`kill -0`)."
  @spec alive?(t() | pos_integer()) :: boolean()
  def alive?(%__MODULE__{pgid: pgid}), do: alive_id?(pgid)
  def alive?(pgid) when is_integer(pgid), do: alive_id?(pgid)

  @doc false
  @spec alive_id?(term()) :: boolean()
  def alive_id?(pgid) do
    case validate_pgid(pgid) do
      :ok ->
        case System.cmd("kill", ["-0", "-#{pgid}"], stderr_to_stdout: true) do
          {_out, 0} -> true
          {_out, _status} -> false
        end

      {:error, _reason} ->
        false
    end
  end

  @doc """
  Bounded TERM → KILL escalation against the whole group, then closes the
  port. Always safe to call twice; returns the observed exit when known.
  """
  @spec terminate(t(), keyword()) :: {:ok, :exited | :killed | :already_exited} | {:error, term()}
  def terminate(%__MODULE__{} = runner, opts \\ []) do
    grace_ms = Keyword.get(opts, :kill_grace_ms, @default_kill_grace_ms)
    reap_ms = Keyword.get(opts, :reap_timeout_ms, @default_reap_timeout_ms)

    cond do
      runner.port == nil ->
        {:ok, :already_exited}

      not alive?(runner) ->
        _ = close_port(runner.port)
        {:ok, :already_exited}

      true ->
        _ = killpg(runner, "TERM")

        case await_exit(runner.port, grace_ms) do
          {:ok, _status} ->
            {:ok, :exited}

          {:timeout, _port} ->
            _ = killpg(runner, "KILL")

            case await_exit(runner.port, reap_ms) do
              {:ok, _status} -> {:ok, :killed}
              {:timeout, _port} -> {:error, :reap_timeout}
            end
        end
    end
  end

  @doc "Closes the port without signalling (the group is already gone)."
  @spec close(t()) :: :ok
  def close(%__MODULE__{port: nil}), do: :ok
  def close(%__MODULE__{port: port}), do: close_port(port)

  # -- Private helpers --

  defp validate_argv([executable | rest] = argv)
       when is_binary(executable) and executable != "" do
    cond do
      not Enum.all?(argv, &(is_binary(&1) and not String.contains?(&1, <<0>>))) ->
        {:error, :invalid_argv}

      true ->
        case resolve_executable(executable) do
          {:ok, resolved} -> {:ok, resolved, rest}
          {:error, _reason} = error -> error
        end
    end
  end

  defp validate_argv(_argv), do: {:error, :invalid_argv}

  defp resolve_executable(executable) do
    cond do
      String.contains?(executable, "/") ->
        if File.regular?(executable) do
          {:ok, executable}
        else
          {:error, {:executable_not_found, executable}}
        end

      true ->
        case System.find_executable(executable) do
          nil -> {:error, {:executable_not_found, executable}}
          resolved -> {:ok, resolved}
        end
    end
  end

  defp setsid?(opts), do: Keyword.get(opts, :setsid, true)

  defp wrap_argv(executable, args, opts) do
    if setsid?(opts) do
      case System.find_executable("python3") do
        nil ->
          if Keyword.get(opts, :allow_no_setsid, false) do
            {:ok, {executable, args}, false}
          else
            {:error, :setsid_unavailable}
          end

        python3 ->
          {:ok, {python3, ["-c", @setsid_wrapper, executable | args]}, true}
      end
    else
      {:ok, {executable, args}, false}
    end
  end

  # Unwrapped launches (no `python3` with `allow_no_setsid`, or `setsid:
  # false`) keep the single immediate check they always had: there is no
  # wrapper to hand-shake with.
  defp verify_launched_leader(_port, os_pid, false, _opts), do: verify_group_leader(os_pid)

  defp verify_launched_leader(port, os_pid, true, opts) do
    timeout = Keyword.get(opts, :handshake_timeout_ms, @default_handshake_timeout_ms)

    with :ok <- await_handshake(port, os_pid, timeout, ""),
         :ok <- verify_group_leader(os_pid) do
      release_wrapper(port)
    else
      {:error, reason} ->
        # The child is still the blocked wrapper (or already gone): nothing
        # of the target ever ran. Kill it before the caller closes the port.
        _ = System.cmd("kill", ["-KILL", to_string(os_pid)], stderr_to_stdout: true)
        {:error, reason}
    end
  end

  # Waits for the wrapper's one handshake line. Nothing else can arrive
  # first: the wrapper writes nothing before it, and the target has not been
  # executed. The line may arrive split across `:stream` chunks.
  defp await_handshake(port, os_pid, timeout, acc) do
    receive do
      {^port, {:data, bytes}} ->
        buffer = acc <> bytes

        case String.split(buffer, "\n", parts: 2) do
          [line, ""] -> check_handshake(line, os_pid)
          [_line, _extra] -> {:error, :setsid_handshake_invalid}
          [_partial] when byte_size(buffer) > 128 -> {:error, :setsid_handshake_invalid}
          [_partial] -> await_handshake(port, os_pid, timeout, buffer)
        end

      {^port, {:exit_status, status}} ->
        {:error, {:setsid_handshake_failed, status}}
    after
      timeout -> {:error, :setsid_handshake_timeout}
    end
  end

  defp check_handshake(@handshake_prefix <> reported, os_pid) do
    case Integer.parse(reported) do
      {^os_pid, ""} -> :ok
      _other -> {:error, :setsid_handshake_invalid}
    end
  end

  defp check_handshake(_line, _os_pid), do: {:error, :setsid_handshake_invalid}

  defp release_wrapper(port) do
    true = Port.command(port, "\n")
    :ok
  rescue
    ArgumentError -> {:error, {:setsid_handshake_failed, :port_closed}}
  end

  defp validate_cd(opts) do
    case Keyword.get(opts, :cd) do
      nil ->
        {:ok, []}

      dir when is_binary(dir) ->
        cond do
          dir == "" or String.contains?(dir, <<0>>) -> {:error, {:invalid_workdir, dir}}
          File.dir?(dir) -> {:ok, [{:cd, to_charlist(dir)}]}
          true -> {:error, {:invalid_workdir, dir}}
        end

      other ->
        {:error, {:invalid_workdir, other}}
    end
  end

  defp open_port(executable, args, opts, cd_opt) do
    try do
      port =
        :erlang.open_port(
          {:spawn_executable, to_charlist(executable)},
          [
            :binary,
            :stream,
            :exit_status,
            :use_stdio,
            :stderr_to_stdout,
            {:args, Enum.map(args, &to_charlist/1)},
            {:env, port_env(Keyword.get(opts, :env, []))}
          ] ++ cd_opt
        )

      {:ok, port}
    catch
      :error, reason -> {:error, {:port_open_failed, reason}}
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

  # Fails closed unless the spawned pid leads its own process group. Without
  # leadership, `killpg` could signal a group the Elf does not own.
  @doc false
  @spec verify_group_leader(pos_integer()) :: :ok | {:error, atom()}
  def verify_group_leader(os_pid) do
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

  # Refuses the BEAM's own process group: signalling it would terminate the
  # VM itself. The BEAM's pid and pgid may differ on Unix, so both are
  # refused; the pgid is read once per VM lifetime and cached.
  defp validate_pgid(pgid) when is_integer(pgid) and pgid > 1 do
    cond do
      pgid == beam_pgid() -> {:error, :refuse_own_process_group}
      pgid == beam_os_pid() -> {:error, :refuse_own_process_group}
      true -> :ok
    end
  end

  defp validate_pgid(_pgid), do: {:error, :invalid_pgid}

  defp beam_os_pid do
    case Integer.parse(to_string(:os.getpid())) do
      {pid, _rest} -> pid
      :error -> -1
    end
  end

  defp beam_pgid do
    case :persistent_term.get({__MODULE__, :beam_pgid}, :unknown) do
      :unknown ->
        pgid = read_beam_pgid()
        :persistent_term.put({__MODULE__, :beam_pgid}, pgid)
        pgid

      cached ->
        cached
    end
  end

  defp read_beam_pgid do
    case System.cmd("ps", ["-o", "pgid=", "-p", to_string(beam_os_pid())], stderr_to_stdout: true) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {pgid, _rest} when pgid > 0 -> pgid
          _other -> nil
        end

      {_output, _status} ->
        nil
    end
  rescue
    _error -> nil
  end

  defp await_exit(port, timeout_ms) do
    receive do
      {^port, {:exit_status, status}} -> {:ok, status}
    after
      timeout_ms -> {:timeout, port}
    end
  end

  # A failed spawn leaves nothing behind: the port may already have closed
  # itself (its child died, e.g. killed after a failed handshake), so it is
  # closed safely, and any message it queued for the caller is discarded.
  defp discard_port(port) do
    close_port(port)
    flush_port(port)
  end

  defp flush_port(port) do
    receive do
      {^port, _message} -> flush_port(port)
    after
      0 -> :ok
    end
  end

  defp close_port(port) do
    try do
      :erlang.port_close(port)
    catch
      :error, _reason -> :ok
    end

    :ok
  end
end
