defmodule Shoestring.Harness.CodexAppServer.GitSandbox do
  @moduledoc false
  alias Shoestring.{State, Worktrees}
  alias Shoestring.Worktrees.PrivateGit

  # Never grant the source repository's shared Git directory. Only independently
  # provisioned, registered per-run storage can extend the default sandbox.
  def policy(workdir, workspace_ref, root \\ State.path(:worktrees)) do
    case Worktrees.get(workdir || "", worktrees_dir: root) do
      {:ok, wt} -> policy_for(wt, workspace_ref, root)
      {:error, :not_found} -> {:ok, nil}
      _ -> {:error, :invalid_git_sandbox_binding}
    end
  end

  defp policy_for(wt, workspace_ref, root) do
    linked? = not no_symlinks?(wt.repo_path, root) or not no_symlinks?(wt.path, root)
    root = physical_path(root)
    wt = %{wt | repo_path: physical_path(wt.repo_path), path: physical_path(wt.path)}
    private = PrivateGit.path(root, wt.run_id)

    if Path.expand(wt.repo_path) == private do
      with false <- linked?,
           true <- wt.workspace_ref == workspace_ref,
           true <- wt.branch == "shoestring/run-#{wt.run_id}",
           true <- no_symlinks?(private, root) and no_symlinks?(wt.path, root),
           {:ok, "gitdir: " <> link} <- File.read(Path.join(wt.path, ".git")),
           gitdir = Path.expand(String.trim(link), wt.path),
           true <- Path.dirname(gitdir) == Path.join(private, "worktrees"),
           true <- no_symlinks?(gitdir, root),
           {:ok, common} <- File.read(Path.join(gitdir, "commondir")),
           true <- Path.expand(String.trim(common), gitdir) == private,
           {:ok, backlink} <- File.read(Path.join(gitdir, "gitdir")),
           true <- String.trim(backlink) == Path.join(wt.path, ".git"),
           {:error, :enoent} <- File.lstat(Path.join(private, "objects/info/alternates")),
           roots = [
             gitdir
             | Enum.map(["objects", "refs/heads", "logs/refs/heads"], &Path.join(private, &1))
           ],
           true <- Enum.all?(roots, &no_symlinks?(&1, root)),
           :ok <- ensure_directories(roots) do
        {:ok,
         %{
           "type" => "workspaceWrite",
           "writableRoots" => [wt.path | roots],
           "networkAccess" => false,
           "excludeSlashTmp" => true,
           "excludeTmpdirEnvVar" => true
         }}
      else
        _ -> {:error, :invalid_git_sandbox_binding}
      end
    else
      {:ok, nil}
    end
  end

  # Platform aliases such as /var -> /private/var must compare by their actual
  # location. Links below the configured root are still refused above.
  defp physical_path(path) do
    path |> Path.expand() |> Path.split() |> resolve_parts("/", 40)
  end

  defp resolve_parts([], acc, _left), do: acc
  defp resolve_parts(_parts, _acc, 0), do: ""

  defp resolve_parts([part | rest], acc, left) do
    candidate = Path.join(acc, part)

    case File.read_link(candidate) do
      {:ok, link} ->
        resolved = Path.expand(link, acc)
        resolve_parts(Path.split(resolved) ++ rest, "/", left - 1)

      _ ->
        resolve_parts(rest, candidate, left)
    end
  end

  defp ensure_directories(roots) do
    Enum.reduce_while(roots, :ok, fn path, :ok ->
      case File.mkdir_p(path) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp no_symlinks?(path, root) do
    root = Path.expand(root)
    path = Path.expand(path)

    if String.starts_with?(path, root <> "/") do
      parts =
        path |> Path.relative_to(root) |> Path.split() |> Enum.scan(root, &Path.join(&2, &1))

      Enum.all?([root | parts], fn part ->
        case File.lstat(part) do
          {:ok, %{type: :symlink}} -> false
          {:ok, _} -> true
          {:error, :enoent} -> true
          _ -> false
        end
      end)
    else
      false
    end
  end
end
