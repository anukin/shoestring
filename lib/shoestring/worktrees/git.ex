defmodule Shoestring.Worktrees.Git do
  @moduledoc """
  Git command executor and output parser for worktree lifecycle and inspection.

  Uses argument arrays for all git invocations, avoiding shell interpolation.
  Command execution is delegated through an injectable runner conforming to
  `Shoestring.Harness.Capacity.CommandRunner`.
  """

  alias Shoestring.Harness.Capacity.SystemCommandRunner

  @default_runner SystemCommandRunner

  @spec ensure_git(module()) :: :ok | {:error, {:missing_git_binary, String.t()}}
  def ensure_git(runner \\ @default_runner) do
    case runner.find_executable("git") do
      path when is_binary(path) and path != "" -> :ok
      _ -> {:error, {:missing_git_binary, "git"}}
    end
  end

  @spec validate_repo(Path.t(), module()) ::
          {:ok, Path.t()} | {:error, {:not_a_git_repo, Path.t()} | term()}
  def validate_repo(repo_path, runner \\ @default_runner) do
    if File.dir?(repo_path) do
      case runner.cmd("git", ["rev-parse", "--show-toplevel"],
             cd: repo_path,
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          {:ok, Path.expand(String.trim(output))}

        {_output, _code} ->
          {:error, {:not_a_git_repo, repo_path}}
      end
    else
      {:error, {:not_a_git_repo, repo_path}}
    end
  end

  @spec resolve_base_commit(Path.t(), String.t(), module()) ::
          {:ok, String.t()} | {:error, {:invalid_base_revision, String.t()}}
  def resolve_base_commit(repo_path, base_revision, runner \\ @default_runner) do
    case runner.cmd(
           "git",
           ["rev-parse", "--verify", "--end-of-options", "#{base_revision}^{commit}"],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        sha = String.trim(output)

        if byte_size(sha) in [40, 64] and sha =~ ~r/\A[0-9a-f]+\z/ do
          {:ok, sha}
        else
          {:error, {:invalid_base_revision, base_revision}}
        end

      {_output, _code} ->
        {:error, {:invalid_base_revision, base_revision}}
    end
  end

  @spec repository_identity(Path.t(), module()) :: {:ok, String.t()} | {:error, term()}
  def repository_identity(repo_path, runner \\ @default_runner) do
    case runner.cmd("git", ["rev-list", "--max-parents=0", "HEAD"],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        shas =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        case shas do
          [root | _] ->
            {:ok, root}

          [] ->
            fallback_repo_identity(repo_path, runner)
        end

      _ ->
        fallback_repo_identity(repo_path, runner)
    end
  end

  defp fallback_repo_identity(repo_path, runner) do
    case runner.cmd(
           "git",
           ["rev-parse", "--path-format=absolute", "--git-common-dir"],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        path = String.trim(output)
        {:ok, :crypto.hash(:sha256, path) |> Base.encode16(case: :lower)}

      _ ->
        {:ok, :crypto.hash(:sha256, Path.expand(repo_path)) |> Base.encode16(case: :lower)}
    end
  end

  @spec branch_exists?(Path.t(), String.t(), module()) :: boolean()
  def branch_exists?(repo_path, branch, runner \\ @default_runner) do
    case runner.cmd("git", ["rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {_output, 0} -> true
      _ -> false
    end
  end

  @spec worktree_add(Path.t(), String.t(), Path.t(), String.t(), module()) ::
          :ok | {:error, {:worktree_add_failed, String.t()}}
  def worktree_add(repo_path, branch, target_path, base_commit, runner \\ @default_runner) do
    case runner.cmd(
           "git",
           ["worktree", "add", "-b", branch, "--end-of-options", target_path, base_commit],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :ok

      {output, _code} ->
        {:error, {:worktree_add_failed, String.trim(output)}}
    end
  end

  @spec worktree_remove(Path.t(), Path.t(), module()) ::
          :ok | {:error, {:cleanup_failed, String.t()}}
  def worktree_remove(repo_path, target_path, runner \\ @default_runner) do
    case runner.cmd("git", ["worktree", "remove", "--force", target_path],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        _ = runner.cmd("git", ["worktree", "prune"], cd: repo_path, stderr_to_stdout: true)
        :ok

      {output, _code} ->
        _ = runner.cmd("git", ["worktree", "prune"], cd: repo_path, stderr_to_stdout: true)

        if String.contains?(output, "is not a working tree") do
          :ok
        else
          {:error, {:cleanup_failed, String.trim(output)}}
        end
    end
  end

  @spec delete_branch(Path.t(), String.t(), module()) ::
          :ok | {:error, {:branch_delete_failed, String.t()}}
  def delete_branch(repo_path, branch, runner \\ @default_runner) do
    case runner.cmd(
           "git",
           ["branch", "-D", "--end-of-options", branch],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, _code} -> {:error, {:branch_delete_failed, String.trim(output)}}
    end
  end

  @spec current_commit(Path.t(), module()) ::
          {:ok, String.t()} | {:error, term()}
  def current_commit(worktree_path, runner \\ @default_runner) do
    case runner.cmd("git", ["rev-parse", "HEAD"], cd: worktree_path, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:git_command_failed, code, String.trim(output)}}
    end
  end

  @spec git_dir(Path.t(), module()) :: {:ok, Path.t()} | {:error, term()}
  def git_dir(worktree_path, runner \\ @default_runner) do
    case runner.cmd("git", ["rev-parse", "--git-dir"],
           cd: worktree_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        dir = String.trim(output)
        {:ok, Path.expand(dir, worktree_path)}

      {output, code} ->
        {:error, {:git_command_failed, code, String.trim(output)}}
    end
  end

  @spec untracked_files(Path.t(), module()) :: {:ok, [String.t()]} | {:error, term()}
  def untracked_files(worktree_path, runner \\ @default_runner) do
    case runner.cmd(
           "git",
           ["ls-files", "--others", "--exclude-standard"],
           cd: worktree_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        files =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        {:ok, files}

      {output, code} ->
        {:error, {:git_command_failed, code, String.trim(output)}}
    end
  end

  @spec changed_files(Path.t(), String.t(), module()) ::
          {:ok, [String.t()]} | {:error, term()}
  def changed_files(worktree_path, base_commit, runner \\ @default_runner) do
    with {:ok, untracked} <- untracked_files(worktree_path, runner),
         {:ok, diff_files} <- files_changed_against_base(worktree_path, base_commit, runner) do
      all =
        (untracked ++ diff_files)
        |> Enum.uniq()
        |> Enum.sort()

      {:ok, all}
    end
  end

  defp files_changed_against_base(worktree_path, base_commit, runner) do
    case runner.cmd(
           "git",
           ["diff", "--name-only", base_commit],
           cd: worktree_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        files =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        {:ok, files}

      {output, code} ->
        {:error, {:git_command_failed, code, String.trim(output)}}
    end
  end

  @spec staged_files(Path.t(), module()) :: {:ok, [String.t()]} | {:error, term()}
  def staged_files(worktree_path, runner \\ @default_runner) do
    case runner.cmd("git", ["diff", "--cached", "--name-only"],
           cd: worktree_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        files =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        {:ok, files}

      {output, code} ->
        {:error, {:git_command_failed, code, String.trim(output)}}
    end
  end

  @spec unstaged_files(Path.t(), module()) :: {:ok, [String.t()]} | {:error, term()}
  def unstaged_files(worktree_path, runner \\ @default_runner) do
    case runner.cmd("git", ["diff", "--name-only"],
           cd: worktree_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        files =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        {:ok, files}

      {output, code} ->
        {:error, {:git_command_failed, code, String.trim(output)}}
    end
  end

  @spec diff_metadata(Path.t(), String.t(), module()) ::
          {:ok, map()} | {:error, term()}
  def diff_metadata(worktree_path, base_commit, runner \\ @default_runner) do
    with {:ok, head_commit} <- current_commit(worktree_path, runner),
         {:ok, untracked} <- untracked_files(worktree_path, runner),
         {:ok, all_changed} <- changed_files(worktree_path, base_commit, runner),
         {:ok, staged} <- staged_files(worktree_path, runner),
         {:ok, unstaged} <- unstaged_files(worktree_path, runner),
         {:ok, commits_ahead} <- count_commits_ahead(worktree_path, base_commit, runner),
         {:ok, status_items} <- parse_status_porcelain(worktree_path, runner),
         {:ok, base_patch} <- run_git(worktree_path, ["diff", base_commit], runner),
         {:ok, dirty_patch} <- run_git(worktree_path, ["diff", "HEAD"], runner),
         {:ok, staged_patch} <- run_git(worktree_path, ["diff", "--cached"], runner),
         {:ok, unstaged_patch} <- run_git(worktree_path, ["diff"], runner),
         {:ok, stat} <- run_git(worktree_path, ["diff", "--stat", base_commit], runner),
         {:ok, shortstat} <- run_git(worktree_path, ["diff", "--shortstat", base_commit], runner) do
      {insertions, deletions} = parse_shortstat(shortstat)
      dirty? = dirty_patch != "" or untracked != [] or staged != []
      clean? = not dirty? and commits_ahead == 0

      {:ok,
       %{
         current_commit: head_commit,
         base_commit: base_commit,
         commits_ahead: commits_ahead,
         dirty?: dirty?,
         clean?: clean?,
         changed_files: all_changed,
         untracked_files: untracked,
         staged_files: staged,
         unstaged_files: unstaged,
         status_items: status_items,
         patch: base_patch,
         dirty_patch: dirty_patch,
         staged_patch: staged_patch,
         unstaged_patch: unstaged_patch,
         stat: stat,
         insertions: insertions,
         deletions: deletions,
         files_changed_count: length(all_changed)
       }}
    end
  end

  defp parse_status_porcelain(worktree_path, runner) do
    case runner.cmd("git", ["status", "--porcelain=v1", "-uall"],
           cd: worktree_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        items =
          output
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn line ->
            if String.length(line) >= 4 do
              index = String.slice(line, 0, 1)
              worktree = String.slice(line, 1, 1)
              path = String.slice(line, 3..-1//1) |> String.trim()
              [%{path: path, index_status: index, worktree_status: worktree}]
            else
              []
            end
          end)

        {:ok, items}

      {output, code} ->
        {:error, {:git_command_failed, code, String.trim(output)}}
    end
  end

  defp count_commits_ahead(worktree_path, base_commit, runner) do
    case runner.cmd("git", ["rev-list", "--count", "#{base_commit}..HEAD"],
           cd: worktree_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {count, ""} -> {:ok, count}
          _ -> {:ok, 0}
        end

      _ ->
        {:ok, 0}
    end
  end

  defp run_git(worktree_path, args, runner) do
    case runner.cmd("git", args, cd: worktree_path, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {:git_command_failed, code, String.trim(output)}}
    end
  end

  defp parse_shortstat(shortstat) when is_binary(shortstat) do
    insertions =
      case Regex.run(~r/(\d+)\s+insertion/, shortstat) do
        [_, count] -> String.to_integer(count)
        _ -> 0
      end

    deletions =
      case Regex.run(~r/(\d+)\s+deletion/, shortstat) do
        [_, count] -> String.to_integer(count)
        _ -> 0
      end

    {insertions, deletions}
  end

  defp parse_shortstat(_), do: {0, 0}
end
