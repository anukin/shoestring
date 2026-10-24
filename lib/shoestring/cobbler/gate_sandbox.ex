defmodule Shoestring.Cobbler.GateSandbox do
  @moduledoc """
  OS confinement for plan acceptance gates.

  A gate executes code the Elf wrote, so it must not be able to do what the
  Elf's own sandbox refuses. Every gate command runs under macOS
  `sandbox-exec` with a profile generated here from Shoestring's own paths,
  never from plan or model text:

  - **Reads.** The rest of the home directory is unreadable (file metadata,
    such as existence and size, stays visible so path lookups work). The
    worktree, its private Git storage and the gate's temporary directory are
    readable, as is everything outside the home directory (the system
    toolchain).
  - **Writes.** Only the worktree (not its `.git` link file) and the gate's
    temporary directory, plus the standard `/dev` sinks.
  - **Network.** No outbound connection, including to localhost. Binding and
    accepting on localhost are allowed because Mix's cross-process compile
    lock listens there; nothing can reach a gate's own listener from inside.
  - **Environment.** Nothing is inherited from the service except `PATH` and
    the locale. `HOME` and `TMPDIR` point at the gate's own temporary
    directory, and Git gets the home-free configuration Elves use. The
    runner removes that directory when the gate finishes (`release/1`).

  The roots come from `GitSandbox.policy/3`: the worktree must be a
  registered run worktree with its own private Git storage. Anything else,
  a missing mechanism (any platform other than macOS), an executable
  installed under the home directory (it could not be read), or a path the
  profile cannot quote safely, makes the gate unavailable. There is no
  unsandboxed fallback.

  The wrapped command is exec'd in place (`sandbox-exec`, then `env -i`), so
  it stays the owned process-group leader and timeout, output limit and
  cancellation behave as before.
  """

  alias Shoestring.Harness.ClaudeHeadless.Sandbox
  alias Shoestring.Harness.CodexAppServer.GitSandbox
  alias Shoestring.{State, Worktrees}

  @sandbox_exec "/usr/bin/sandbox-exec"
  @env_exec "/usr/bin/env"
  @profile_version 1
  @locale ~w(LANG LC_ALL LC_CTYPE)
  @dev_sinks ~w(/dev/null /dev/zero /dev/tty /dev/dtracehelper)

  @typedoc "`macos_seatbelt:v<profile version>:sha256:<digest of the exact profile>`."
  @type identity :: String.t()
  @type t :: %{argv: [String.t()], identity: identity(), temp_dir: Path.t()}

  @temp_prefix "shoestring-gate"

  @doc """
  Wraps a trusted gate `argv` for `worktree`. Options: `:worktrees_dir` (the
  service's worktree root), `:home` (defaults to the user's home) and
  `:sandbox_exec` (the mechanism's path).
  """
  @spec wrap([String.t()], Path.t(), keyword()) ::
          {:ok, t()} | {:error, {:gate_unavailable, %{reason: atom()}}}
  def wrap([executable | _] = argv, worktree, opts \\ []) do
    sandbox_exec = Keyword.get(opts, :sandbox_exec, @sandbox_exec)
    root = Keyword.get(opts, :worktrees_dir) || State.path(:worktrees)
    home = GitSandbox.physical_path(Keyword.get_lazy(opts, :home, &System.user_home!/0))

    with :ok <- mechanism(sandbox_exec),
         {:ok, path, store} <- roots(worktree, root),
         :ok <- toolchain(executable, home),
         {:ok, tmp} <- temp_dir(),
         {:ok, profile} <- release_on_error(profile(path, store, tmp, home), tmp) do
      pairs = Enum.map(env(tmp), fn {key, value} -> key <> "=" <> value end)

      {:ok,
       %{
         argv: [sandbox_exec, "-p", profile, @env_exec, "-i" | pairs] ++ argv,
         temp_dir: tmp,
         identity:
           "macos_seatbelt:v#{@profile_version}:sha256:" <>
             (:crypto.hash(:sha256, profile) |> Base.encode16(case: :lower))
       }}
    else
      {:error, reason} -> {:error, {:gate_unavailable, %{reason: reason}}}
    end
  end

  defp mechanism(sandbox_exec) do
    if :os.type() == {:unix, :darwin} and File.regular?(sandbox_exec),
      do: :ok,
      else: {:error, :no_sandbox_mechanism}
  end

  # Roots are the worktree, its gitdir, then <store>/objects and refs.
  defp roots(worktree, root) do
    with {:ok, wt} <- Worktrees.get(worktree, worktrees_dir: root),
         {:ok, %{"writableRoots" => [path | _] = roots}} <-
           GitSandbox.policy(worktree, wt.workspace_ref, root) do
      {:ok, path, roots |> Enum.at(2) |> Path.dirname()}
    else
      {:error, :invalid_git_sandbox_binding} -> {:error, :invalid_run_worktree}
      _ -> {:error, :not_a_private_run_worktree}
    end
  end

  defp toolchain(executable, home) do
    case System.find_executable(executable) do
      nil ->
        {:error, :executable_not_found}

      found ->
        if String.starts_with?(GitSandbox.physical_path(found), home <> "/"),
          do: {:error, :toolchain_under_home},
          else: :ok
    end
  end

  defp temp_dir, do: Shoestring.SandboxTemp.create(@temp_prefix)

  defp release_on_error({:error, _} = error, tmp) do
    _ = Shoestring.SandboxTemp.remove(tmp, @temp_prefix)
    error
  end

  defp release_on_error(ok, _tmp), do: ok

  @doc "Removes the gate's temporary directory once its command has finished."
  @spec release(t()) :: :ok | {:error, :not_a_sandbox_temp_dir}
  def release(%{temp_dir: dir}), do: Shoestring.SandboxTemp.remove(dir, @temp_prefix)

  @doc """
  The names of the only environment variables a gate can see (a locale
  variable only when the service has it set).
  """
  @spec environment_names() :: [String.t()]
  def environment_names do
    (~w(PATH HOME TMPDIR PYTHONDONTWRITEBYTECODE) ++
       @locale ++ Enum.map(Sandbox.git_env(), &elem(&1, 0)))
    |> Enum.sort()
  end

  # Python writes no bytecode, so a project gate running Python leaves the
  # worktree as clean as it found it (the runner checks after the gate).
  defp env(tmp) do
    locale = for key <- @locale, value = System.get_env(key), do: {key, value}

    [
      {"PATH", System.get_env("PATH") || "/usr/bin:/bin"},
      {"HOME", tmp},
      {"TMPDIR", tmp},
      {"PYTHONDONTWRITEBYTECODE", "1"}
    ] ++ locale ++ Sandbox.git_env()
  end

  defp profile(worktree, store, tmp, home) do
    if Enum.all?([worktree, store, tmp, home], &quotable?/1) do
      sinks = Enum.map_join(@dev_sinks, " ", &"(literal #{q(&1)})")

      # Later rules take precedence over earlier ones.
      {:ok,
       """
       (version 1)
       (allow default)
       (deny network*)
       (allow network-bind (local ip "localhost:*"))
       (allow network-inbound (local ip "localhost:*"))
       (deny file-write*)
       (allow file-write* (subpath #{q(worktree)}) (subpath #{q(tmp)}) #{sinks} (regex #"^/dev/fd/"))
       (deny file-write* (literal #{q(Path.join(worktree, ".git"))}))
       (deny file-read* (subpath #{q(home)}))
       (allow file-read-metadata (subpath #{q(home)}))
       (allow file-read* (subpath #{q(worktree)}) (subpath #{q(store)}) (subpath #{q(tmp)}))
       """}
    else
      {:error, :unsafe_sandbox_path}
    end
  end

  defp q(path), do: ~s("#{path}")

  defp quotable?(path) do
    String.starts_with?(path, "/") and path != "/" and
      not String.contains?(path, ["\"", "\\"]) and
      not String.match?(path, ~r/[[:cntrl:]]/u)
  end
end
