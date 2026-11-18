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
    toolchain). A dispatch-managed Go installation is also readable.
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

  import Bitwise

  alias Shoestring.Harness.ClaudeHeadless.Sandbox
  alias Shoestring.Harness.CodexAppServer.GitSandbox
  alias Shoestring.{State, Worktrees}

  @sandbox_exec "/usr/bin/sandbox-exec"
  @env_exec "/usr/bin/env"
  @profile_version 2
  @profile_version_without_toolchain 1
  @locale ~w(LANG LC_ALL LC_CTYPE)
  @dev_sinks ~w(/dev/null /dev/zero /dev/tty /dev/dtracehelper)

  @typedoc "`macos_seatbelt:v<profile version>:sha256:<digest of the exact profile>`."
  @type identity :: String.t()
  @type t :: %{argv: [String.t()], identity: identity(), temp_dir: Path.t()}

  @temp_prefix "shoestring-gate"

  @doc """
  Wraps a trusted gate `argv` for `worktree`. Options: `:worktrees_dir` (the
  service's worktree root), `:home` (defaults to the user's home) and
  `:sandbox_exec` (the mechanism's path), and `:go_root` (the trusted
  dispatch-managed Go installation). Go modules must already be available
  offline, for example in a checked-in vendor directory.
  """
  @spec wrap([String.t()], Path.t(), keyword()) ::
          {:ok, t()} | {:error, {:gate_unavailable, %{reason: atom()}}}
  def wrap([executable | _] = argv, worktree, opts \\ []) do
    sandbox_exec = Keyword.get(opts, :sandbox_exec, @sandbox_exec)
    root = Keyword.get(opts, :worktrees_dir) || State.path(:worktrees)
    home = GitSandbox.physical_path(Keyword.get_lazy(opts, :home, &System.user_home!/0))

    with :ok <- mechanism(sandbox_exec),
         {:ok, path, store} <- roots(worktree, root),
         {:ok, setup_root} <- setup_root(Keyword.get(opts, :setup_root)),
         {:ok, go_root} <- toolchain(executable, home, Keyword.get(opts, :go_root), setup_root),
         {:ok, tmp} <- temp_dir(),
         {:ok, profile} <-
           release_on_error(profile(path, store, tmp, home, go_root, setup_root), tmp) do
      pairs = Enum.map(env(tmp, go_root, setup_root), fn {key, value} -> key <> "=" <> value end)

      version =
        if go_root || setup_root, do: @profile_version, else: @profile_version_without_toolchain

      {:ok,
       %{
         argv: [sandbox_exec, "-p", profile, @env_exec, "-i" | pairs] ++ argv,
         temp_dir: tmp,
         identity:
           "macos_seatbelt:v#{version}:sha256:" <>
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

  defp toolchain(executable, home, root, setup_root) when is_binary(root) do
    physical = GitSandbox.physical_path(root)
    binary = Path.join(physical, "bin/go")

    if Path.type(root) == :absolute and File.regular?(binary) and
         String.starts_with?(GitSandbox.physical_path(binary), physical <> "/") and
         match?({:ok, %{mode: mode}} when band(mode, 0o111) != 0, File.stat(binary)) do
      if executable == "go" do
        {:ok, physical}
      else
        case toolchain(executable, home, nil, setup_root) do
          {:ok, nil} -> {:ok, physical}
          error -> error
        end
      end
    else
      {:error, :managed_toolchain_unavailable}
    end
  end

  defp toolchain(_executable, _home, root, _setup_root) when not is_nil(root),
    do: {:error, :managed_toolchain_unavailable}

  defp toolchain(executable, home, nil, setup_root) do
    candidate = setup_root && Path.join([setup_root, "bin", executable])

    case (executable_in_setup?(candidate, setup_root) && candidate) ||
           System.find_executable(executable) do
      nil ->
        {:error, :executable_not_found}

      found ->
        if not executable_in_setup?(found, setup_root) and
             String.starts_with?(GitSandbox.physical_path(found), home <> "/"),
           do: {:error, :toolchain_under_home},
           else: {:ok, nil}
    end
  end

  defp setup_root(nil), do: {:ok, nil}

  defp setup_root(root) when is_binary(root) do
    if Path.type(root) == :absolute and File.dir?(root),
      do: {:ok, GitSandbox.physical_path(root)},
      else: {:error, :managed_setup_unavailable}
  end

  defp setup_root(_), do: {:error, :managed_setup_unavailable}

  defp executable_in_setup?(path, root) when is_binary(path) and is_binary(root) do
    File.regular?(path) and
      String.starts_with?(GitSandbox.physical_path(path), root <> "/") and
      match?({:ok, %{mode: mode}} when band(mode, 0o111) != 0, File.stat(path))
  end

  defp executable_in_setup?(_, _), do: false

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
    (~w(PATH HOME TMPDIR PYTHONDONTWRITEBYTECODE GOROOT GOTOOLCHAIN GOENV GOPROXY GOSUMDB GOCACHE GOMODCACHE) ++
       @locale ++ Enum.map(Sandbox.git_env(), &elem(&1, 0)))
    |> Enum.sort()
  end

  # Python writes no bytecode, so a project gate running Python leaves the
  # worktree as clean as it found it (the runner checks after the gate).
  defp env(tmp, go_root, setup_root) do
    locale = for key <- @locale, value = System.get_env(key), do: {key, value}

    [
      {"PATH",
       Enum.join(
         Enum.reject(
           [
             setup_root && Path.join(setup_root, "bin"),
             go_root && Path.join(go_root, "bin"),
             System.get_env("PATH") || "/usr/bin:/bin"
           ],
           &is_nil/1
         ),
         ":"
       )},
      {"HOME", tmp},
      {"TMPDIR", tmp},
      {"PYTHONDONTWRITEBYTECODE", "1"}
    ] ++ setup_env(setup_root) ++ go_env(tmp, go_root) ++ locale ++ Sandbox.git_env()
  end

  defp setup_env(nil), do: []
  defp setup_env(root), do: [{"SHOESTRING_SETUP_DIR", root}]

  defp go_env(_tmp, nil), do: []

  defp go_env(tmp, root) do
    [
      {"GOROOT", root},
      {"GOTOOLCHAIN", "local"},
      {"GOENV", "off"},
      {"GOPROXY", "off"},
      {"GOSUMDB", "off"},
      {"GOCACHE", Path.join(tmp, "go-cache")},
      {"GOMODCACHE", Path.join(tmp, "go-mod")}
    ]
  end

  defp profile(worktree, store, tmp, home, go_root, setup_root) do
    if Enum.all?(
         Enum.reject([worktree, store, tmp, home, go_root, setup_root], &is_nil/1),
         &quotable?/1
       ) do
      sinks = Enum.map_join(@dev_sinks, " ", &"(literal #{q(&1)})")

      toolchain_read =
        [go_root, setup_root]
        |> Enum.reject(&is_nil/1)
        |> Enum.map_join("", &" (subpath #{q(&1)})")

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
       (allow file-read* (subpath #{q(worktree)}) (subpath #{q(store)}) (subpath #{q(tmp)})#{toolchain_read})
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
