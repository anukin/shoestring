defmodule Shoestring.Worktrees.PrivateGit do
  @moduledoc """
  Copies a pinned local commit into per-run Git storage. No alternates, hardlinks,
  remotes, source hooks or source configuration are shared with the run.
  """
  alias Shoestring.Cobbler.GateProcess

  def path(worktrees_dir, run_id),
    do: Path.expand(Path.join([worktrees_dir, ".git-repositories", run_id]))

  def prepare(source, base, worktrees_dir, run_id) do
    destination = path(worktrees_dir, run_id)

    with {:error, :enoent} <- File.lstat(destination),
         true <- safe_parent?(Path.dirname(destination)),
         :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- command(["git", "init", "--bare", destination], source),
         :ok <-
           command(
             ["git", "-c", "core.hooksPath=/dev/null", "fetch", "--no-tags", "--", source, base],
             destination
           ),
         :ok <- copy_identity(source, destination) do
      {:ok, destination}
    else
      {:ok, _} -> {:error, :private_git_already_exists}
      false -> {:error, :unsafe_private_git_parent}
      error -> error
    end
  end

  defp safe_parent?(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> true
      {:error, :enoent} -> true
      _ -> false
    end
  end

  defp copy_identity(source, destination) do
    Enum.reduce_while(["user.name", "user.email"], :ok, fn key, :ok ->
      case GateProcess.run(["git", "config", "--get", key], source, 15_000, 65_536) do
        {:ok, %{exit_status: 0, output: value}} ->
          case command(["git", "config", key, String.trim(value)], destination) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end

        {:ok, %{exit_status: 1}} ->
          {:cont, :ok}

        _ ->
          {:halt, {:error, :private_git_identity_failed}}
      end
    end)
  end

  defp command(argv, cwd) do
    case GateProcess.run(argv, cwd, 30_000, 65_536) do
      {:ok, %{exit_status: 0}} -> :ok
      _ -> {:error, :private_git_preparation_failed}
    end
  end
end
