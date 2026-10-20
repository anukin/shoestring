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

  UNVERIFIED until a live run: that `allowRead` for the run's paths takes
  precedence over `denyRead` for the home directory when the state directory
  lives under it (the live evaluations used a temporary directory).
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

  @type t :: %{settings: map(), options: [String.t()], env: [{String.t(), String.t()}]}

  @doc """
  Prepares the sandbox for a run worktree bound to `workspace_ref`. Options:
  `:worktrees_dir` (the service's worktree root) and `:home` (defaults to the
  user's home).
  """
  @spec prepare(Path.t(), String.t(), keyword()) :: {:ok, t()} | {:error, atom()}
  def prepare(workdir, workspace_ref, opts \\ []) do
    root = Keyword.get_lazy(opts, :worktrees_dir, fn -> Shoestring.State.path(:worktrees) end)
    home = Path.expand(Keyword.get_lazy(opts, :home, &System.user_home!/0))

    case GitSandbox.policy(workdir, workspace_ref, root) do
      {:ok, %{"writableRoots" => [worktree | _] = roots}} ->
        # Roots are the worktree, its gitdir, then <store>/objects and refs.
        repository = roots |> Enum.at(2) |> Path.dirname()
        settings = settings(roots, worktree, repository, home)
        {:ok, %{settings: settings, options: options(settings), env: env()}}

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

  defp settings(roots, worktree, repository, home) do
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
          "denyRead" => [home],
          "allowRead" => [worktree, repository]
        },
        "network" => %{"allowedDomains" => []}
      }
    }
  end

  # The flag set the live fan-out ran with (CLI 2.1.300 and 2.1.301).
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
      "--effort",
      "medium",
      "--permission-mode",
      "dontAsk",
      "--permission-prompts",
      "none"
    ]
  end
end
