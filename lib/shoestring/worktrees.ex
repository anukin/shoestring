defmodule Shoestring.Worktrees do
  @moduledoc """
  Provisions, tracks, inspects, and safely cleans up isolated Git worktrees.

  Guarantees:
  - Source isolation: the user's source repository checkout is never modified,
    reset, cleaned, or stashed.
  - Safe allocation: creates a unique branch and worktree directory under
    Shoestring's state root.
  - Fail-loud safety: refuses to overwrite or reuse unrecognized existing directories.
  - Forensic preservation: failed and suspended worktrees are preserved by default.
  - Safe cleanup: only completed or cancelled worktrees are cleaned up, and only
    when opting into an explicit safe policy.
  """

  alias Shoestring.Harness.Capacity.SystemCommandRunner
  alias Shoestring.State
  alias Shoestring.Worktrees.{Git, Record, Worktree}

  @run_id_regex ~r/\A[A-Za-z0-9_-]+\z/

  @type create_error ::
          {:invalid_run_id, String.t()}
          | {:run_id_already_exists, String.t()}
          | {:missing_git_binary, String.t()}
          | {:not_a_git_repo, Path.t()}
          | {:invalid_base_revision, String.t()}
          | {:branch_already_exists, String.t()}
          | {:unrecognized_existing_directory, Path.t()}
          | {:directory_already_exists, Path.t()}
          | :source_checkout_protection
          | {:worktree_add_failed, String.t()}
          | {:record_save_failed, term()}
          | {:git_command_failed, non_neg_integer(), String.t()}
          | term()

  @type cleanup_error ::
          :cleanup_policy_required
          | :source_checkout_protection
          | :record_mismatch
          | {:worktree_preserved, Worktree.status()}
          | {:worktree_active, Worktree.status()}
          | {:unrecognized_directory, Path.t()}
          | {:unsafe_branch_deletion, String.t()}
          | {:cleanup_failed, String.t() | {:rm_rf_failed, File.posix(), Path.t()}}
          | {:record_diverged, term()}
          | term()

  @doc """
  Provisions a new isolated worktree for the given run and base revision.

  ## Options
    * `:base_revision` - git revision to base the worktree on (defaults to `"HEAD"`).
    * `:branch` - custom branch name (defaults to `"shoestring/run-\#{run_id}"`).
    * `:path` - custom worktree directory path (defaults to `Path.join(worktrees_dir, "run-\#{run_id}")`).
    * `:worktrees_dir` - parent worktrees root (defaults to `Shoestring.State.path(:worktrees)`).
    * `:runner` - command runner conforming to `Shoestring.Harness.Capacity.CommandRunner`
      (defaults to `Shoestring.Harness.Capacity.SystemCommandRunner`).
    * `:metadata` - optional map of arbitrary metadata to persist with the worktree.
  """
  @spec create(Path.t(), String.t(), String.t() | keyword(), keyword()) ::
          {:ok, Worktree.t()} | {:error, create_error()}
  def create(repo_path, run_id, opts_or_base_revision \\ [], opts \\ [])

  def create(repo_path, run_id, base_revision, opts) when is_binary(base_revision) do
    opts = Keyword.put(opts, :base_revision, base_revision)
    do_create(repo_path, to_string(run_id), opts)
  end

  def create(repo_path, run_id, opts, _) when is_list(opts) do
    do_create(repo_path, to_string(run_id), opts)
  end

  defp do_create(repo_path, run_id, opts) do
    runner = Keyword.get(opts, :runner, SystemCommandRunner)
    base_rev = Keyword.get(opts, :base_revision, "HEAD")
    worktrees_dir = resolve_worktrees_dir(opts)

    with :ok <- validate_run_id(run_id),
         :ok <- validate_run_id_not_registered(worktrees_dir, run_id),
         :ok <- Git.ensure_git(runner),
         {:ok, canonical_repo_path} <- Git.validate_repo(repo_path, runner),
         {:ok, base_commit} <- Git.resolve_base_commit(canonical_repo_path, base_rev, runner),
         {:ok, repo_id} <- Git.repository_identity(canonical_repo_path, runner),
         target_path = resolve_target_path(worktrees_dir, run_id, opts),
         branch = Keyword.get(opts, :branch, "shoestring/run-#{run_id}"),
         :ok <- validate_not_source_repo(target_path, canonical_repo_path),
         :ok <- validate_target_directory_available(target_path, worktrees_dir, runner),
         :ok <- validate_branch_available(canonical_repo_path, branch, runner),
         :ok <- File.mkdir_p(worktrees_dir),
         :ok <- Git.worktree_add(canonical_repo_path, branch, target_path, base_commit, runner) do
      workspace_ref = compute_workspace_ref(target_path, worktrees_dir, run_id)

      worktree = %Worktree{
        run_id: run_id,
        repo_id: repo_id,
        repo_path: canonical_repo_path,
        base_commit: base_commit,
        branch: branch,
        path: target_path,
        workspace_ref: workspace_ref,
        status: :active,
        created_at: DateTime.utc_now(),
        metadata: Keyword.get(opts, :metadata, %{})
      }

      case Record.save(worktree, worktrees_dir, runner) do
        :ok ->
          {:ok, worktree}

        {:error, {:record_save_failed, _}} = error ->
          _ = Git.worktree_remove(canonical_repo_path, target_path, runner)
          _ = Record.delete_record(worktree, worktrees_dir, runner)
          error

        {:error, reason} ->
          _ = Git.worktree_remove(canonical_repo_path, target_path, runner)
          _ = Record.delete_record(worktree, worktrees_dir, runner)
          {:error, {:record_save_failed, reason}}
      end
    end
  end

  @doc """
  Retrieves a worktree by run ID or worktree path.
  """
  @spec get(String.t() | Path.t(), keyword()) ::
          {:ok, Worktree.t()} | {:error, :not_found | term()}
  def get(run_id_or_path, opts \\ []) do
    worktrees_dir = resolve_worktrees_dir(opts)
    runner = Keyword.get(opts, :runner, SystemCommandRunner)

    case Record.load_by_run_id(to_string(run_id_or_path), worktrees_dir, runner) do
      {:ok, %Worktree{} = wt} ->
        {:ok, wt}

      {:error, :not_found} ->
        Record.load_by_path(run_id_or_path, worktrees_dir, runner)

      error ->
        error
    end
  end

  @doc """
  Lists all recognized, durable worktrees.
  """
  @spec list(keyword()) :: [Worktree.t()]
  def list(opts \\ []) do
    worktrees_dir = resolve_worktrees_dir(opts)
    Record.list_records(worktrees_dir)
  end

  @doc """
  Updates the lifecycle status of a worktree.
  """
  @spec update_status(Worktree.t() | String.t(), atom(), keyword()) ::
          {:ok, Worktree.t()} | {:error, term()}
  def update_status(worktree_or_run_id, new_status, opts \\ []) do
    with true <- Worktree.valid_status?(new_status) || {:error, {:invalid_status, new_status}},
         {:ok, %Worktree{} = wt} <- resolve_worktree(worktree_or_run_id, opts) do
      worktrees_dir = resolve_worktrees_dir(opts)
      runner = Keyword.get(opts, :runner, SystemCommandRunner)
      updated = %Worktree{wt | status: new_status}

      case Record.save(updated, worktrees_dir, runner) do
        :ok -> {:ok, updated}
        error -> error
      end
    else
      false -> {:error, {:invalid_status, new_status}}
      error -> error
    end
  end

  @doc """
  Returns current HEAD commit in the worktree.
  """
  @spec current_commit(Worktree.t() | Path.t() | String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def current_commit(worktree_or_path, opts \\ []) do
    with {:ok, path} <- resolve_path(worktree_or_path, opts) do
      runner = Keyword.get(opts, :runner, SystemCommandRunner)
      Git.current_commit(path, runner)
    end
  end

  @doc """
  Returns a sorted list of all files changed in the worktree relative to the base commit,
  including uncommitted modifications and untracked files.
  """
  @spec changed_files(Worktree.t() | Path.t() | String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def changed_files(worktree_or_path, opts \\ []) do
    with {:ok, wt} <- resolve_worktree(worktree_or_path, opts) do
      runner = Keyword.get(opts, :runner, SystemCommandRunner)
      Git.changed_files(wt.path, wt.base_commit, runner)
    end
  end

  @doc """
  Returns detailed diff metadata for the worktree.
  """
  @spec diff(Worktree.t() | Path.t() | String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def diff(worktree_or_path, opts \\ []) do
    with {:ok, wt} <- resolve_worktree(worktree_or_path, opts) do
      runner = Keyword.get(opts, :runner, SystemCommandRunner)
      Git.diff_metadata(wt.path, wt.base_commit, runner)
    end
  end

  @doc """
  Returns comprehensive status information for the worktree, combining
  identity, current commit, commits ahead, clean/dirty state, and diff metadata.
  """
  @spec status(Worktree.t() | Path.t() | String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def status(worktree_or_path, opts \\ []) do
    with {:ok, wt} <- resolve_worktree(worktree_or_path, opts),
         {:ok, diff_meta} <- diff(wt, opts) do
      {:ok,
       Map.merge(diff_meta, %{
         worktree: wt,
         run_id: wt.run_id,
         repo_id: wt.repo_id,
         repo_path: wt.repo_path,
         branch: wt.branch,
         path: wt.path,
         workspace_ref: wt.workspace_ref,
         status: wt.status
       })}
    end
  end

  @doc """
  Safely cleans up a completed or cancelled worktree.

  Cleanup requires explicitly opting into a safe policy (`policy: :safe`).
  The authoritative record is reloaded from disk to prevent caller spoofing
  or preservation bypass.
  Preserved worktrees (`:failed`, `:suspended`, `:active`) are never cleaned
  up by default; `:override_preserved` must be explicitly provided.
  Branch deletion requires the branch to match the recorded branch and start
  with `shoestring/`.
  Unrecognized existing directories are never deleted.
  """
  @spec cleanup(Worktree.t() | Path.t() | String.t(), keyword()) ::
          :ok | {:error, cleanup_error()}
  def cleanup(worktree_or_path, opts \\ []) do
    policy = Keyword.get(opts, :policy)
    override_preserved = Keyword.get(opts, :override_preserved, false)
    override_active = Keyword.get(opts, :override_active, false)
    delete_branch? = Keyword.get(opts, :delete_branch, false)
    worktrees_dir = resolve_worktrees_dir(opts)
    runner = Keyword.get(opts, :runner, SystemCommandRunner)

    cond do
      policy != :safe ->
        {:error, :cleanup_policy_required}

      true ->
        with {:ok, supplied_wt} <- resolve_worktree(worktree_or_path, opts),
             {:ok, authoritative_wt} <-
               reload_authoritative_record(supplied_wt, worktrees_dir, runner),
             :ok <- validate_struct_consistency(supplied_wt, authoritative_wt),
             :ok <- validate_cleanup_recognition(authoritative_wt.path, worktrees_dir, runner),
             :ok <- validate_not_source_repo(authoritative_wt.path, authoritative_wt.repo_path),
             :ok <-
               validate_cleanup_status(
                 authoritative_wt.status,
                 override_preserved,
                 override_active
               ),
             :ok <- validate_branch_for_deletion(delete_branch?, authoritative_wt.branch) do
          execute_cleanup(authoritative_wt, worktrees_dir, runner, opts)
        end
    end
  end

  @doc """
  Returns true if the directory is a recognized Shoestring-managed worktree.
  """
  @spec recognized?(Path.t(), keyword()) :: boolean()
  def recognized?(target_path, opts \\ []) do
    worktrees_dir = resolve_worktrees_dir(opts)
    runner = Keyword.get(opts, :runner, SystemCommandRunner)
    Record.recognized?(target_path, worktrees_dir, runner)
  end

  # Helpers

  defp validate_run_id(run_id) do
    if is_binary(run_id) and run_id =~ @run_id_regex do
      :ok
    else
      {:error, {:invalid_run_id, run_id}}
    end
  end

  defp validate_run_id_not_registered(worktrees_dir, run_id) do
    if File.exists?(Record.record_path(worktrees_dir, run_id)) do
      {:error, {:run_id_already_exists, run_id}}
    else
      :ok
    end
  end

  defp resolve_worktrees_dir(opts) do
    Keyword.get(opts, :worktrees_dir) ||
      State.path(:worktrees)
  end

  defp resolve_target_path(worktrees_dir, run_id, opts) do
    case Keyword.get(opts, :path) do
      path when is_binary(path) and path != "" ->
        Path.expand(path)

      _ ->
        Path.expand(Path.join(worktrees_dir, "run-#{run_id}"))
    end
  end

  defp compute_workspace_ref(target_path, worktrees_dir, run_id) do
    case Path.relative_to(target_path, worktrees_dir) do
      ^target_path -> "run-#{run_id}"
      rel -> rel
    end
  end

  defp validate_not_source_repo(target_path, repo_path) do
    expanded_target = canonical_path(target_path)
    expanded_repo = canonical_path(repo_path)

    cond do
      expanded_target == expanded_repo ->
        {:error, :source_checkout_protection}

      String.starts_with?(expanded_target <> "/", expanded_repo <> "/") ->
        {:error, :source_checkout_protection}

      String.starts_with?(expanded_repo <> "/", expanded_target <> "/") ->
        {:error, :source_checkout_protection}

      File.exists?(Path.join(expanded_target, ".git/HEAD")) ->
        {:error, :source_checkout_protection}

      true ->
        :ok
    end
  end

  defp canonical_path(path) do
    expanded = Path.expand(path)
    resolve_symlinks(Path.split(expanded), "/")
  end

  defp resolve_symlinks([], acc), do: acc

  defp resolve_symlinks([part | rest], acc) do
    candidate = Path.join(acc, part)

    case :file.read_link(candidate) do
      {:ok, link} ->
        link_str = to_string(link)

        resolved =
          if Path.type(link_str) == :absolute do
            link_str
          else
            Path.expand(link_str, acc)
          end

        resolve_symlinks(rest, resolved)

      _ ->
        resolve_symlinks(rest, candidate)
    end
  end

  defp validate_target_directory_available(target_path, worktrees_dir, runner) do
    if File.exists?(target_path) do
      if Record.recognized?(target_path, worktrees_dir, runner) do
        {:error, {:directory_already_exists, target_path}}
      else
        {:error, {:unrecognized_existing_directory, target_path}}
      end
    else
      :ok
    end
  end

  defp validate_branch_available(repo_path, branch, runner) do
    if Git.branch_exists?(repo_path, branch, runner) do
      {:error, {:branch_already_exists, branch}}
    else
      :ok
    end
  end

  defp reload_authoritative_record(%Worktree{} = wt, worktrees_dir, runner) do
    case Record.load_by_run_id(wt.run_id, worktrees_dir, runner) do
      {:ok, %Worktree{} = auth} ->
        {:ok, auth}

      {:error, :not_found} ->
        case Record.load_by_path(wt.path, worktrees_dir, runner) do
          {:ok, %Worktree{} = auth} -> {:ok, auth}
          {:error, :not_found} -> {:error, {:unrecognized_directory, wt.path}}
          error -> error
        end

      error ->
        error
    end
  end

  defp validate_struct_consistency(%Worktree{} = supplied, %Worktree{} = stored) do
    if supplied.run_id != stored.run_id or
         canonical_path(supplied.path) != canonical_path(stored.path) or
         canonical_path(supplied.repo_path) != canonical_path(stored.repo_path) or
         supplied.branch != stored.branch or
         supplied.status != stored.status do
      {:error, :record_mismatch}
    else
      :ok
    end
  end

  defp validate_branch_for_deletion(false, _branch), do: :ok

  defp validate_branch_for_deletion(true, branch) do
    if is_binary(branch) and String.starts_with?(branch, "shoestring/") do
      :ok
    else
      {:error, {:unsafe_branch_deletion, branch}}
    end
  end

  defp validate_cleanup_recognition(path, worktrees_dir, runner) do
    if Record.recognized?(path, worktrees_dir, runner) do
      :ok
    else
      {:error, {:unrecognized_directory, path}}
    end
  end

  defp validate_cleanup_status(status, override_preserved, override_active) do
    case status do
      status when status in [:completed, :cancelled] ->
        :ok

      status when status in [:failed, :suspended] ->
        if override_preserved do
          :ok
        else
          {:error, {:worktree_preserved, status}}
        end

      :active ->
        if override_active do
          :ok
        else
          {:error, {:worktree_active, status}}
        end

      other ->
        {:error, {:invalid_status, other}}
    end
  end

  defp execute_cleanup(%Worktree{} = wt, worktrees_dir, runner, opts) do
    with :ok <- Git.worktree_remove(wt.repo_path, wt.path, runner),
         :ok <- remove_worktree_directory(wt.path) do
      Record.delete_record(wt, worktrees_dir, runner)

      if Keyword.get(opts, :delete_branch, false) do
        _ = Git.delete_branch(wt.repo_path, wt.branch, runner)
      end

      :ok
    end
  end

  defp remove_worktree_directory(path) do
    if File.exists?(path) do
      case File.rm_rf(path) do
        {:ok, _files} ->
          :ok

        {:error, reason, file} ->
          {:error, {:cleanup_failed, {:rm_rf_failed, reason, file}}}
      end
    else
      :ok
    end
  end

  defp resolve_worktree(%Worktree{} = wt, _opts), do: {:ok, wt}

  defp resolve_worktree(run_id_or_path, opts) when is_binary(run_id_or_path) do
    case get(run_id_or_path, opts) do
      {:ok, %Worktree{} = wt} ->
        {:ok, wt}

      {:error, :not_found} ->
        if File.dir?(run_id_or_path) do
          {:error, {:unrecognized_directory, Path.expand(run_id_or_path)}}
        else
          {:error, :not_found}
        end

      error ->
        error
    end
  end

  defp resolve_worktree(other, _opts), do: {:error, {:invalid_argument, other}}

  defp resolve_path(%Worktree{path: path}, _opts), do: {:ok, path}

  defp resolve_path(path, opts) when is_binary(path) do
    case resolve_worktree(path, opts) do
      {:ok, %Worktree{path: wt_path}} ->
        {:ok, wt_path}

      _ ->
        if File.dir?(path) do
          {:ok, Path.expand(path)}
        else
          {:error, :not_found}
        end
    end
  end

  defp resolve_path(other, _opts), do: {:error, {:invalid_argument, other}}
end
