defmodule Shoestring.Worktrees.Worktree do
  @moduledoc """
  Represents an isolated Git worktree provisioned for a single run.
  """

  @enforce_keys [
    :run_id,
    :repo_id,
    :repo_path,
    :base_commit,
    :branch,
    :path,
    :workspace_ref,
    :status,
    :created_at
  ]

  defstruct [
    :run_id,
    :repo_id,
    :repo_path,
    :base_commit,
    :branch,
    :path,
    :workspace_ref,
    :status,
    :created_at,
    metadata: %{}
  ]

  @type status :: :active | :completed | :failed | :suspended | :cancelled

  @type t :: %__MODULE__{
          run_id: String.t(),
          repo_id: String.t(),
          repo_path: Path.t(),
          base_commit: String.t(),
          branch: String.t(),
          path: Path.t(),
          workspace_ref: String.t(),
          status: status(),
          created_at: DateTime.t(),
          metadata: map()
        }

  @valid_statuses [:active, :completed, :failed, :suspended, :cancelled]

  @spec valid_statuses() :: [status()]
  def valid_statuses, do: @valid_statuses

  @spec valid_status?(atom()) :: boolean()
  def valid_status?(status) when status in @valid_statuses, do: true
  def valid_status?(_), do: false

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = worktree) do
    %{
      "format_version" => 1,
      "run_id" => worktree.run_id,
      "repo_id" => worktree.repo_id,
      "repo_path" => worktree.repo_path,
      "base_commit" => worktree.base_commit,
      "branch" => worktree.branch,
      "path" => worktree.path,
      "workspace_ref" => worktree.workspace_ref,
      "status" => Atom.to_string(worktree.status),
      "created_at" => DateTime.to_iso8601(worktree.created_at),
      "metadata" => worktree.metadata || %{}
    }
  end

  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(data) when is_map(data) do
    with {:ok, 1} <- check_format_version(data["format_version"]),
         {:ok, run_id} <- required_string(data["run_id"], :run_id),
         {:ok, repo_id} <- required_string(data["repo_id"], :repo_id),
         {:ok, repo_path} <- required_string(data["repo_path"], :repo_path),
         {:ok, base_commit} <- required_string(data["base_commit"], :base_commit),
         {:ok, branch} <- required_string(data["branch"], :branch),
         {:ok, path} <- required_string(data["path"], :path),
         {:ok, workspace_ref} <- required_string(data["workspace_ref"], :workspace_ref),
         {:ok, status} <- parse_status(data["status"]),
         {:ok, created_at} <- parse_datetime(data["created_at"]) do
      metadata = if is_map(data["metadata"]), do: data["metadata"], else: %{}

      {:ok,
       %__MODULE__{
         run_id: run_id,
         repo_id: repo_id,
         repo_path: repo_path,
         base_commit: base_commit,
         branch: branch,
         path: path,
         workspace_ref: workspace_ref,
         status: status,
         created_at: created_at,
         metadata: metadata
       }}
    end
  end

  def from_map(_), do: {:error, :invalid_worktree_map}

  defp check_format_version(1), do: {:ok, 1}
  defp check_format_version(_), do: {:error, :unsupported_format_version}

  defp required_string(val, _field) when is_binary(val) and val != "", do: {:ok, val}
  defp required_string(_val, field), do: {:error, {:missing_required_field, field}}

  defp parse_status(status) when is_binary(status) do
    case status do
      "active" -> {:ok, :active}
      "completed" -> {:ok, :completed}
      "failed" -> {:ok, :failed}
      "suspended" -> {:ok, :suspended}
      "cancelled" -> {:ok, :cancelled}
      _ -> {:error, {:invalid_status, status}}
    end
  end

  defp parse_status(status) when status in @valid_statuses, do: {:ok, status}
  defp parse_status(other), do: {:error, {:invalid_status, other}}

  defp parse_datetime(dt) when is_binary(dt) do
    case DateTime.from_iso8601(dt) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, {:invalid_datetime, dt}}
    end
  end

  defp parse_datetime(%DateTime{} = dt), do: {:ok, dt}
  defp parse_datetime(other), do: {:error, {:invalid_datetime, other}}
end
