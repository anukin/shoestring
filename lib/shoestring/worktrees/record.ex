defmodule Shoestring.Worktrees.Record do
  @moduledoc """
  Durable JSON persistence and recognition logic for worktree metadata.

  Stores worktree metadata:
  1. In the state root: `<worktrees_dir>/.records/<run_id>.json` (authoritative)
  2. Inside the worktree's Git directory: `<gitdir>/shoestring_worktree.json`

  This ensures worktrees are durable across restarts, discoverable by run_id,
  and verifiable by directory path, without polluting the working tree files
  monitored by Git.
  """

  alias Shoestring.Worktrees.{Git, Worktree}

  @records_subdir ".records"
  @meta_filename "shoestring_worktree.json"

  @spec records_dir(Path.t()) :: Path.t()
  def records_dir(worktrees_dir), do: Path.join(worktrees_dir, @records_subdir)

  @spec record_path(Path.t(), String.t()) :: Path.t()
  def record_path(worktrees_dir, run_id) do
    Path.join(records_dir(worktrees_dir), "#{run_id}.json")
  end

  @run_id_regex ~r/\A[A-Za-z0-9_-]+\z/

  @spec save(Worktree.t(), Path.t(), module()) :: :ok | {:error, term()}
  def save(%Worktree{} = worktree, worktrees_dir, runner) do
    with :ok <- validate_run_id(worktree.run_id),
         :ok <- ensure_records_dir(worktrees_dir),
         {:ok, json} <- encode_worktree(worktree) do
      record_file = record_path(worktrees_dir, worktree.run_id)
      prior_content = snapshot_prior_content(record_file)

      case write_file(record_file, json) do
        :ok ->
          case Git.git_dir(worktree.path, runner) do
            {:ok, gitdir} ->
              gitdir_file = Path.join(gitdir, @meta_filename)

              case File.write(gitdir_file, json) do
                :ok ->
                  :ok

                {:error, reason} ->
                  rollback_record_file(record_file, prior_content)
                  {:error, {:record_save_failed, {:gitdir_write_failed, reason}}}
              end

            {:error, reason} ->
              rollback_record_file(record_file, prior_content)
              {:error, {:record_save_failed, {:gitdir_unavailable, reason}}}
          end

        error ->
          error
      end
    end
  end

  @spec load_by_run_id(String.t(), Path.t(), module() | nil) ::
          {:ok, Worktree.t()} | {:error, :not_found | {:record_diverged, map()} | term()}
  def load_by_run_id(run_id, worktrees_dir, runner \\ nil) do
    path = record_path(worktrees_dir, run_id)

    case File.read(path) do
      {:ok, content} ->
        case decode_worktree(content) do
          {:ok, %Worktree{} = rec_wt} ->
            if runner do
              verify_gitdir_consistency(rec_wt, runner)
            else
              {:ok, rec_wt}
            end

          error ->
            error
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec load_by_path(Path.t(), Path.t(), module()) ::
          {:ok, Worktree.t()} | {:error, :not_found | {:record_diverged, map()} | term()}
  def load_by_path(worktree_path, worktrees_dir, runner) do
    canonical = Path.expand(worktree_path)

    # .records is authoritative: consult find_in_records_by_path first
    case find_in_records_by_path(canonical, worktrees_dir) do
      {:ok, %Worktree{} = rec_wt} ->
        # Check if gitdir metadata exists and whether they diverge
        verify_gitdir_consistency(rec_wt, runner)

      {:error, :not_found} ->
        # Fallback to gitdir copy if .records entry is missing
        case read_gitdir_metadata(canonical, runner) do
          {:ok, %Worktree{} = gitdir_wt} ->
            if Path.expand(gitdir_wt.path) == canonical do
              {:ok, gitdir_wt}
            else
              {:error, :not_found}
            end

          _ ->
            {:error, :not_found}
        end
    end
  end

  @spec list_records(Path.t()) :: [Worktree.t()]
  def list_records(worktrees_dir) do
    dir = records_dir(worktrees_dir)

    if File.dir?(dir) do
      case File.ls(dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.map(&Path.join(dir, &1))
          |> Enum.reduce([], fn file_path, acc ->
            case File.read(file_path) do
              {:ok, content} ->
                case decode_worktree(content) do
                  {:ok, wt} -> [wt | acc]
                  _ -> acc
                end

              _ ->
                acc
            end
          end)
          |> Enum.sort_by(& &1.created_at, {:desc, DateTime})

        _ ->
          []
      end
    else
      []
    end
  end

  @spec recognized?(Path.t(), Path.t(), module()) :: boolean()
  def recognized?(target_path, worktrees_dir, runner) do
    case load_by_path(target_path, worktrees_dir, runner) do
      {:ok, %Worktree{}} -> true
      _ -> false
    end
  end

  @spec delete_record(Worktree.t(), Path.t(), module()) :: :ok
  def delete_record(%Worktree{} = worktree, worktrees_dir, _runner) do
    _ = File.rm(record_path(worktrees_dir, worktree.run_id))
    :ok
  end

  defp verify_gitdir_consistency(%Worktree{} = rec_wt, runner) do
    case read_gitdir_metadata(rec_wt.path, runner) do
      {:ok, %Worktree{} = gitdir_wt} ->
        if diverged?(rec_wt, gitdir_wt) do
          {:error, {:record_diverged, %{records: rec_wt, gitdir: gitdir_wt}}}
        else
          {:ok, rec_wt}
        end

      _ ->
        {:ok, rec_wt}
    end
  end

  defp diverged?(%Worktree{} = a, %Worktree{} = b) do
    a.run_id != b.run_id or
      a.status != b.status or
      a.branch != b.branch or
      a.base_commit != b.base_commit or
      Path.expand(a.path) != Path.expand(b.path) or
      Path.expand(a.repo_path) != Path.expand(b.repo_path)
  end

  defp read_gitdir_metadata(worktree_path, runner) do
    case Git.git_dir(worktree_path, runner) do
      {:ok, gitdir} ->
        meta_file = Path.join(gitdir, @meta_filename)

        case File.read(meta_file) do
          {:ok, content} -> decode_worktree(content)
          _ -> {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp find_in_records_by_path(canonical_path, worktrees_dir) do
    records = list_records(worktrees_dir)

    case Enum.find(records, fn wt -> Path.expand(wt.path) == canonical_path end) do
      %Worktree{} = wt -> {:ok, wt}
      nil -> {:error, :not_found}
    end
  end

  defp encode_worktree(%Worktree{} = worktree) do
    case Jason.encode(Worktree.to_map(worktree), pretty: true) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:record_save_failed, reason}}
    end
  end

  defp write_file(path, content) do
    case File.write(path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, {:record_save_failed, reason}}
    end
  end

  defp decode_worktree(json_string) do
    case Jason.decode(json_string) do
      {:ok, data} when is_map(data) ->
        Worktree.from_map(data)

      _ ->
        {:error, :corrupted_record}
    end
  end

  defp validate_run_id(run_id) do
    if is_binary(run_id) and run_id =~ @run_id_regex do
      :ok
    else
      {:error, {:invalid_run_id, run_id}}
    end
  end

  defp ensure_records_dir(worktrees_dir) do
    case File.mkdir_p(records_dir(worktrees_dir)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:record_save_failed, reason}}
    end
  end

  defp snapshot_prior_content(record_file) do
    case File.read(record_file) do
      {:ok, bytes} -> bytes
      _ -> nil
    end
  end

  defp rollback_record_file(record_file, nil) do
    _ = File.rm(record_file)
    :ok
  end

  defp rollback_record_file(record_file, prior_content) when is_binary(prior_content) do
    _ = File.write(record_file, prior_content)
    :ok
  end
end
