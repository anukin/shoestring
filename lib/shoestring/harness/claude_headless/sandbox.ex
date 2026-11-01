defmodule Shoestring.Harness.ClaudeHeadless.Sandbox do
  @moduledoc """
  Per-run sandbox launch settings for a Claude Elf, following the reviewed
  live-evaluation launcher (`tools/live_eval/claude_fixture_launcher.py`) that
  iteration 7's live fan-out ran under.

  The writable roots come from `Shoestring.Harness.CodexAppServer.GitSandbox`,
  the same reviewed check Codex runs use: a registered run worktree with its
  own private Git storage, the expected branch and backlinks, no alternates
  and no symlinked roots. Anything else refuses the launch; there is no
  fallback to an unsandboxed or permission-bypassing launch.

  Claude may write only to those roots, so the source repository is never
  writable. It may not read the home directory except the run's own paths.
  Bash runs sandboxed with no network, no saved session, no inherited settings
  files, MCP servers or slash commands, and without permission bypass. Git
  gets a home-free configuration, without which a sandboxed commit cannot read
  its global config (live attempt 1). Python writes no bytecode: an Elf that
  ran its tests otherwise left untracked `__pycache__/` directories, and the
  checks refuse a dirty worktree (iteration 8 live escalation run).

  `allowRead` for the run's paths takes precedence over `denyRead` for the
  home directory when the state directory lives under it, as an installed
  service's does (VERIFIED offline with Claude Code 2.1.316 against a scripted
  model, 2026-10-31: the worktree and its Git storage were readable, another
  file in the home directory was not, and writes outside the worktree, to
  `/tmp` and to the network were refused).
  """

  alias Shoestring.Harness.CodexAppServer.GitSandbox

  @git_env [
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_COUNT", "2"},
    {"GIT_CONFIG_KEY_0", "core.excludesFile"},
    {"GIT_CONFIG_VALUE_0", "/dev/null"},
    {"GIT_CONFIG_KEY_1", "core.attributesFile"},
    {"GIT_CONFIG_VALUE_1", "/dev/null"}
  ]

  @type t :: %{
          settings: map(),
          options: [String.t()],
          env: [{String.t(), String.t()}],
          temp_dir: Path.t()
        }

  @temp_prefix "sc"

  @doc """
  Prepares the sandbox for a run worktree bound to `workspace_ref`. Options:
  `:worktrees_dir` (the service's worktree root), `:home` (defaults to the
  user's home) and `:permissions`, what the person added to the agent
  (`Shoestring.Agents.Permissions`: extra readable and writable folders and
  the hosts its commands may reach).

  Each launch gets its own temporary directory (`CLAUDE_CODE_TMPDIR`), which
  its owner removes with `release/1` once the process tree is reaped. Claude
  Code's sandbox lets Bash write to its temporary directory, by default the
  shared `/tmp/claude-<uid>` that holds every other Claude session's files
  (VERIFIED offline 2026-10-31 with 2.1.316: a sandboxed worker's `touch`
  there succeeded). That shared directory is also denied for writing, so if
  Claude ever falls back to it the run's commands fail visibly instead.
  """
  @spec prepare(Path.t(), String.t(), keyword()) :: {:ok, t()} | {:error, atom()}
  def prepare(workdir, workspace_ref, opts \\ []) do
    root = Keyword.get_lazy(opts, :worktrees_dir, fn -> Shoestring.State.path(:worktrees) end)
    home = Path.expand(Keyword.get_lazy(opts, :home, &System.user_home!/0))

    case GitSandbox.policy(workdir, workspace_ref, root) do
      {:ok, %{"writableRoots" => [worktree | _] = roots}} ->
        with {:ok, temp} <- Shoestring.SandboxTemp.create_short(@temp_prefix) do
          # Roots are the worktree, its gitdir, then <store>/objects and refs.
          repository = roots |> Enum.at(2) |> Path.dirname()

          settings =
            roots
            |> settings(worktree, repository, home, shared_temp(temp))
            |> widen(Keyword.get(opts, :permissions))

          {:ok,
           %{
             settings: settings,
             options: options(settings),
             env: [{"CLAUDE_CODE_TMPDIR", temp} | env()],
             temp_dir: temp
           }}
        end

      {:ok, nil} ->
        {:error, :not_a_private_run_worktree}

      {:error, _reason} ->
        {:error, :invalid_run_worktree}
    end
  end

  @doc "The environment every sandboxed Claude Elf gets."
  @spec env() :: [{String.t(), String.t()}]
  def env,
    do: [
      {"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1"},
      {"PYTHONDONTWRITEBYTECODE", "1"} | @git_env
    ]

  @doc "The home-free Git configuration, without the Claude-specific variables."
  @spec git_env() :: [{String.t(), String.t()}]
  def git_env, do: @git_env

  @doc "Removes a launch's temporary directory once its process tree is reaped."
  @spec release(Path.t() | nil) :: :ok | {:error, :not_a_sandbox_temp_dir}
  def release(dir), do: Shoestring.SandboxTemp.remove_short(dir, @temp_prefix)

  # Claude Code's shared temporary directory, `/tmp/claude-<uid>`, by both
  # spellings (macOS's /tmp is a link to /private/tmp). The uid is the
  # owner of the directory just created.
  defp shared_temp(temp) do
    %File.Stat{uid: uid} = File.stat!(temp)
    name = "claude-#{uid}"
    Enum.uniq([Path.join("/tmp", name), Path.join(Shoestring.SandboxTemp.short_root(), name)])
  end

  defp widen(settings, permissions) when permissions in [nil, %{}], do: settings

  defp widen(settings, permissions) do
    reads = permissions["read_paths"] || []
    writes = permissions["write_paths"] || []
    hosts = permissions["network_hosts"] || []

    settings
    |> update_in(["sandbox", "filesystem", "allowRead"], &Enum.uniq(&1 ++ reads ++ writes))
    |> update_in(["sandbox", "filesystem", "allowWrite"], &Enum.uniq(&1 ++ writes))
    |> put_in(["sandbox", "network", "allowedDomains"], hosts)
  end

  defp settings(roots, worktree, repository, home, deny_write) do
    %{
      "alwaysThinkingEnabled" => false,
      "attribution" => %{"commit" => "", "pr" => ""},
      "sandbox" => %{
        "enabled" => true,
        "failIfUnavailable" => true,
        "autoAllowBashIfSandboxed" => true,
        "allowUnsandboxedCommands" => false,
        "excludedCommands" => [],
        "filesystem" => %{
          "allowWrite" => roots,
          "denyWrite" => deny_write,
          "denyRead" => [home],
          "allowRead" => [worktree, repository]
        },
        "network" => %{"allowedDomains" => []}
      }
    }
  end

  @doc """
  The effort a sandboxed launch runs at when its binding chose none: the
  live fan-out's. It is not one of `options`, because Claude Code keeps the
  last `--effort` it is given and a binding's effort must win (2.1.310).
  """
  def default_effort, do: "medium"

  # The flag set the live fan-out ran with (CLI 2.1.300 and 2.1.301), except
  # its `--effort medium`: see `default_effort/0`.
  defp options(settings) do
    [
      "--safe-mode",
      "--restricted",
      "--setting-sources",
      "",
      "--settings",
      Jason.encode!(settings),
      "--strict-mcp-config",
      "--mcp-config",
      ~s({"mcpServers":{}}),
      "--disable-slash-commands",
      "--no-session-persistence",
      "--permission-mode",
      "dontAsk",
      "--permission-prompts",
      "none"
    ]
  end
end
