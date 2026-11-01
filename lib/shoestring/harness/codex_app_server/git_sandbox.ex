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
  @profile "shoestring_run"

  @doc """
  The Codex permission profile a run with `policy` (from `policy/3`) works
  under, passed per thread as a `config` override so nothing is written to
  the person's Codex home: the system readable, the person's `home` denied
  (Shoestring's own state, keys and every other checkout live there), the
  run's own roots writable, and no network (a profile's default).

  The legacy `sandboxPolicy` (`workspaceWrite`) Shoestring sent before let a
  worker's commands read the whole home directory, `~/.ssh` and Shoestring's
  database included (VERIFIED offline with Codex 0.166.0, 2026-11-01); what a
  command reads reaches the model provider as its output.
  """
  def permissions(
        %{"writableRoots" => [_worktree, _gitdir, objects | _] = roots},
        home \\ System.user_home!()
      ) do
    # Git reads the private store's own files (config, HEAD) beside its
    # writable objects and refs.
    entries = roots |> Map.new(&{&1, "write"}) |> Map.put_new(Path.dirname(objects), "read")
    profile(entries, home)
  end

  @doc """
  The read-only twin of `permissions/2`, for a Codex explorer or coordinator:
  the system and `paths` (its repository) readable, the rest of `home`
  denied, nothing writable, no network. The legacy read-only sandbox let
  their commands read the whole home directory too (VERIFIED offline, same
  date).
  """
  def read_only_permissions(paths, home \\ System.user_home!()) do
    paths
    |> Enum.flat_map(&with_git_dirs/1)
    |> Map.new(&{&1, "read"})
    |> profile(home)
  end

  # A checkout's Git directories, when its `.git` is a file pointing
  # elsewhere (a private run worktree, or a linked worktree of the person's):
  # Git reads them for `git log` and `git status`.
  defp with_git_dirs(path) do
    path = physical_path(path)

    case File.read(Path.join(path, ".git")) do
      {:ok, "gitdir: " <> link} ->
        gitdir = Path.expand(String.trim(link), path)

        common =
          case File.read(Path.join(gitdir, "commondir")) do
            {:ok, common} -> [physical_path(Path.expand(String.trim(common), gitdir))]
            {:error, _} -> []
          end

        Enum.uniq([path, physical_path(gitdir) | common])

      _ ->
        [path]
    end
  end

  # The home directory is denied entry by entry, never as a whole: a denied
  # ancestor makes Git's realpath of a private worktree's `.git` file fail
  # ("fatal: Invalid path '<home>'", VERIFIED offline with Codex 0.166.0),
  # so the directories leading to the run's own paths stay traversable and
  # everything beside them at each level is denied. An entry created in home
  # after the launch is not covered.
  defp profile(entries, home) do
    filesystem =
      home
      |> physical_path()
      |> denied_beside(Map.keys(entries))
      |> Map.new(&{&1, "deny"})
      |> Map.merge(entries)
      |> Map.put(":root", "read")

    %{
      "default_permissions" => @profile,
      "permissions" => %{@profile => %{"filesystem" => filesystem}}
    }
  end

  # Everything under `dir` except the branches leading to `keep`; a kept path
  # is left to its own entry. A directory on a branch that cannot be listed
  # raises, failing the launch, rather than leaving its entries readable.
  defp denied_beside(dir, keep) do
    keep = Enum.filter(keep, &String.starts_with?(&1, dir <> "/"))
    if keep == [], do: [dir], else: denied_beside(dir, keep, [])
  end

  defp denied_beside(dir, keep, acc) do
    dir
    |> File.ls!()
    |> Enum.sort()
    |> Enum.reduce(acc, fn name, acc ->
      path = Path.join(dir, name)

      cond do
        path in keep -> acc
        Enum.any?(keep, &String.starts_with?(&1, path <> "/")) -> denied_beside(path, keep, acc)
        true -> [path | acc]
      end
    end)
  end

  @doc """
  A profile from `permissions/2` or `read_only_permissions/2` as `codex exec`
  `-c` overrides (TOML values; a JSON string is a valid TOML basic string).
  """
  def config_flags(%{"default_permissions" => name, "permissions" => profiles}) do
    table =
      profiles[name]["filesystem"]
      |> Enum.sort()
      |> Enum.map_join(",", fn {path, access} ->
        Jason.encode!(path) <> "=" <> Jason.encode!(access)
      end)

    [
      "-c",
      "default_permissions=" <> Jason.encode!(name),
      "-c",
      "permissions.#{name}.filesystem={#{table}}"
    ]
  end

  @doc false
  def physical_path(path) do
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
