defmodule Shoestring.Harness.OpencodeAcp.Sandbox do
  @moduledoc """
  OS confinement for an opencode Elf. opencode has no sandbox of its own, so
  the whole `opencode acp` process tree runs under macOS `sandbox-exec` with a
  profile generated here from Shoestring's own paths, never from plan or model
  text (the pattern `Shoestring.Cobbler.GateSandbox` uses for gates):

  - **Writes.** The run worktree and its private Git storage (the roots
    `GitSandbox.policy/3` returns for a registered run worktree), opencode's
    own data, state and cache directories (its session database lives there),
    a fresh temporary directory for this run (`TMPDIR` points at it), and the
    standard `/dev` sinks. The source repository is never writable.
  - **Reads.** The rest of the home directory is unreadable except those
    paths, opencode's configuration directory (and the targets of symlinks at
    its top level: an `AGENTS.md` linked elsewhere is read through its real
    path, and a denied read makes opencode hang the prompt — VERIFIED, 2.0.31)
    and its install directory.
    opencode reads its own login from its data directory; Shoestring never
    opens it.
  - **Network.** Allowed: opencode must reach its model provider.
  - **Environment.** `HOME` and `TMPDIR` are the run's temporary directory
    and the XDG variables name opencode's real directories, so opencode keeps
    its own login and configuration while home-relative lookups find nothing.
    opencode otherwise reads `~/.claude` and `~/.agents` when a session starts
    (VERIFIED, 2.0.31: `session/new` fails with those reads denied) — Claude's
    settings and transcripts must not be readable by the agent. Claude Code
    compatibility and self-update are switched off, Git gets the home-free
    configuration Elves use, and Python writes no bytecode.

  Anything else (another platform, a worktree that is not a private run
  worktree, a path the profile cannot quote) refuses the launch; there is no
  unsandboxed fallback. VERIFIED live (2.0.31): a sandboxed task wrote its
  file in the worktree and ran `ls`; asked to read a file elsewhere in home
  and to write outside the worktree, both shell commands got "Operation not
  permitted".
  """

  alias Shoestring.Harness.ClaudeHeadless.Sandbox, as: ClaudeSandbox
  alias Shoestring.Harness.CodexAppServer.GitSandbox

  @sandbox_exec "/usr/bin/sandbox-exec"
  @profile_version 1
  @dev_sinks ~w(/dev/null /dev/zero /dev/tty /dev/dtracehelper)

  @type t :: %{
          command: String.t(),
          args: [String.t()],
          env: [{String.t(), String.t()}],
          identity: String.t(),
          temp_dir: Path.t()
        }

  @temp_prefix "shoestring-opencode"

  @doc """
  Builds the sandboxed launch for `opencode acp` in `workdir`. Options:
  `:worktrees_dir`, `:home`, `:executable` (opencode's path),
  `:sandbox_exec` and `:env` (the environment XDG directories are read from).
  """
  @spec prepare(Path.t(), String.t(), keyword()) :: {:ok, t()} | {:error, atom()}
  def prepare(workdir, workspace_ref, opts \\ []) do
    sandbox_exec = Keyword.get(opts, :sandbox_exec, @sandbox_exec)
    root = Keyword.get_lazy(opts, :worktrees_dir, fn -> Shoestring.State.path(:worktrees) end)
    home = GitSandbox.physical_path(Keyword.get_lazy(opts, :home, &System.user_home!/0))
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)

    with :ok <- mechanism(sandbox_exec),
         {:ok, executable} <- executable(Keyword.get(opts, :executable)),
         {:ok, roots} <- roots(workdir, workspace_ref, root),
         paths = opencode_paths(home, env),
         {:ok, tmp} <- temp_dir(),
         {:ok, profile} <-
           release_on_error(profile(roots, paths, install_dir(executable), tmp, home), tmp) do
      {:ok,
       %{
         command: sandbox_exec,
         args: ["-p", profile, executable, "acp"],
         env: env(tmp, paths),
         temp_dir: tmp,
         identity:
           "macos_seatbelt:v#{@profile_version}:sha256:" <>
             (:crypto.hash(:sha256, profile) |> Base.encode16(case: :lower))
       }}
    end
  end

  defp mechanism(sandbox_exec) do
    if :os.type() == {:unix, :darwin} and File.regular?(sandbox_exec),
      do: :ok,
      else: {:error, :no_sandbox_mechanism}
  end

  defp executable(nil) do
    case System.find_executable("opencode") do
      nil -> {:error, :executable_not_found}
      path -> {:ok, GitSandbox.physical_path(path)}
    end
  end

  defp executable(path) when is_binary(path), do: {:ok, GitSandbox.physical_path(path)}

  defp roots(workdir, workspace_ref, root) do
    case GitSandbox.policy(workdir, workspace_ref, root) do
      {:ok, %{"writableRoots" => [_ | _] = roots}} -> {:ok, roots}
      {:ok, nil} -> {:error, :not_a_private_run_worktree}
      {:error, _reason} -> {:error, :invalid_run_worktree}
    end
  end

  # Symlinks at the top of opencode's configuration directory, resolved to
  # their real paths. opencode follows them; nothing else under home becomes
  # readable.
  defp config_links(config) do
    case File.ls(config) do
      {:ok, names} ->
        for name <- names,
            path = Path.join(config, name),
            {:ok, %File.Stat{type: :symlink}} <- [File.lstat(path)],
            target = GitSandbox.physical_path(path),
            File.exists?(target),
            do: target

      {:error, _} ->
        []
    end
  end

  defp env(tmp, paths) do
    [
      {"HOME", tmp},
      {"TMPDIR", tmp},
      {"XDG_DATA_HOME", Path.dirname(paths.data)},
      {"XDG_STATE_HOME", Path.dirname(paths.state)},
      {"XDG_CACHE_HOME", Path.dirname(paths.cache)},
      {"XDG_CONFIG_HOME", Path.dirname(paths.config)},
      {"OPENCODE_DISABLE_CLAUDE_CODE", "1"},
      {"OPENCODE_DISABLE_AUTOUPDATE", "1"}
    ] ++
      Enum.reject(
        ClaudeSandbox.env(),
        &(elem(&1, 0) == "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC")
      )
  end

  defp temp_dir, do: Shoestring.SandboxTemp.create(@temp_prefix)

  @doc "Removes a run's temporary directory once its process tree has been reaped."
  @spec release(Path.t() | nil) :: :ok | {:error, :not_a_sandbox_temp_dir}
  def release(dir), do: Shoestring.SandboxTemp.remove(dir, @temp_prefix)

  defp release_on_error({:error, _} = error, tmp) do
    _ = release(tmp)
    error
  end

  defp release_on_error(ok, _tmp), do: ok

  # opencode follows the XDG base directories (`opencode debug paths`).
  defp opencode_paths(home, env) do
    xdg = fn name, default ->
      (Map.get(env, name) || Path.join(home, default))
      |> Path.join("opencode")
      |> GitSandbox.physical_path()
    end

    %{
      data: xdg.("XDG_DATA_HOME", ".local/share"),
      state: xdg.("XDG_STATE_HOME", ".local/state"),
      cache: xdg.("XDG_CACHE_HOME", ".cache"),
      config: xdg.("XDG_CONFIG_HOME", ".config")
    }
  end

  # `~/.opencode/bin/opencode` → `~/.opencode`; a system install reads fine
  # without a rule.
  defp install_dir(executable), do: executable |> Path.dirname() |> Path.dirname()

  defp profile(roots, paths, install, tmp, home) do
    # Roots are the worktree, its gitdir, then <store>/objects and refs; Git
    # reads the rest of the private store (config, HEAD) too.
    store = roots |> Enum.at(2) |> Path.dirname()
    writable = roots ++ [paths.data, paths.state, paths.cache, tmp]
    readable = writable ++ [store, paths.config, install] ++ config_links(paths.config)

    if Enum.all?([home | readable], &quotable?/1) do
      sinks = Enum.map_join(@dev_sinks, " ", &"(literal #{q(&1)})")
      subpaths = fn list -> Enum.map_join(list, " ", &"(subpath #{q(&1)})") end
      [worktree | _] = roots

      # Later rules take precedence over earlier ones.
      {:ok,
       """
       (version 1)
       (allow default)
       (deny file-write*)
       (allow file-write* #{subpaths.(writable)} #{sinks} (regex #"^/dev/fd/") (regex #"^/dev/ttys"))
       (deny file-write* (literal #{q(Path.join(worktree, ".git"))}))
       (deny file-read* (subpath #{q(home)}))
       (allow file-read-metadata (subpath #{q(home)}))
       (allow file-read* #{subpaths.(readable)})
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
