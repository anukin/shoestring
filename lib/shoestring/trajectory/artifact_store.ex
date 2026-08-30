defmodule Shoestring.Trajectory.ArtifactStore do
  @moduledoc "Bounded content-addressed artifact storage under the Shoestring state directory."

  import Ecto.Query

  alias Shoestring.Repo
  alias Shoestring.Trajectory.{Artifact, Task}

  @default_max_size 10 * 1024 * 1024
  @metadata_fields [:media_type, :redacted]

  @doc "Writes bytes atomically and persists only portable artifact metadata."
  @spec put(Ecto.UUID.t(), binary(), map(), keyword()) ::
          {:ok, Artifact.t()} | {:error, term()}
  def put(goal_id, bytes, attrs, opts \\ [])

  def put(goal_id, bytes, attrs, opts) when is_binary(bytes) do
    with {:ok, normalized_goal_id} <- cast_uuid(goal_id, :goal_id),
         :ok <- enforce_size(bytes, max_size(opts)),
         {:ok, metadata} <- cast_metadata(attrs),
         {:ok, task_id} <- cast_optional_uuid(Keyword.get(opts, :task_id), :task_id),
         :ok <- validate_task_ownership(normalized_goal_id, task_id),
         root <- root(opts),
         :ok <- File.mkdir_p(root),
         sha256 <- sha256(bytes),
         location <- Path.join(normalized_goal_id, sha256),
         :ok <- validate_location(location),
         :ok <- validate_path_components(root, location),
         {:ok, created?} <- write_atomically(root, location, bytes) do
      artifact = %Artifact{
        id: Ecto.UUID.generate(),
        goal_id: normalized_goal_id,
        task_id: task_id,
        sha256: sha256,
        byte_size: byte_size(bytes),
        media_type: metadata.media_type,
        location: location,
        redacted: metadata.redacted
      }

      case persist_artifact(artifact) do
        {:ok, artifact} ->
          {:ok, artifact}

        {:error, reason} ->
          maybe_remove_created(root, location, created?)
          {:error, reason}
      end
    end
  end

  def put(_goal_id, _bytes, _attrs, _opts), do: {:error, :artifact_bytes_must_be_binary}

  @doc "Reads an artifact only after containment, size, and SHA-256 verification."
  @spec read(Ecto.UUID.t(), keyword()) ::
          {:ok, %{artifact: Artifact.t(), bytes: binary()}} | {:error, term()}
  def read(artifact_id, opts \\ []) do
    with {:ok, normalized_id} <- cast_uuid(artifact_id, :id),
         %Artifact{} = artifact <- Repo.get(Artifact, normalized_id),
         :ok <- validate_artifact_metadata(artifact),
         {:ok, path} <- verified_path(root(opts), artifact.location),
         {:ok, bytes} <- File.read(path) do
      cond do
        sha256(bytes) != artifact.sha256 -> {:error, {:artifact_corrupt, :hash}}
        byte_size(bytes) != artifact.byte_size -> {:error, {:artifact_corrupt, :size}}
        true -> {:ok, %{artifact: artifact, bytes: bytes}}
      end
    else
      nil -> {:error, {:artifact_missing_metadata, artifact_id}}
      {:error, {:artifact_unsafe_location, _location} = error} -> {:error, error}
      {:error, :enoent} -> {:error, {:artifact_missing, artifact_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Resolves the configured artifact root without creating a second state convention."
  @spec root(keyword()) :: Path.t()
  def root(opts \\ []) do
    Keyword.get(opts, :root) ||
      Application.get_env(:shoestring, :artifact_root) ||
      Shoestring.State.path(:artifacts)
  end

  @doc false
  @spec max_size(keyword()) :: non_neg_integer()
  def max_size(opts \\ []) do
    case Keyword.get(
           opts,
           :max_size,
           Application.get_env(:shoestring, :artifact_max_size, @default_max_size)
         ) do
      value when is_integer(value) and value >= 0 -> value
      _invalid -> @default_max_size
    end
  end

  defp cast_metadata(attrs) when is_map(attrs) do
    unknown_fields =
      attrs
      |> Map.keys()
      |> Enum.reject(
        &(&1 in @metadata_fields or
            &1 in Enum.map(@metadata_fields, fn field -> Atom.to_string(field) end))
      )

    media_type = Map.get(attrs, :media_type, Map.get(attrs, "media_type"))
    redacted = Map.get(attrs, :redacted, Map.get(attrs, "redacted", false))

    cond do
      unknown_fields != [] ->
        {:error, {:invalid_artifact_attributes, unknown_fields}}

      not is_binary(media_type) or String.trim(media_type) == "" ->
        {:error, {:invalid_artifact_attributes, :media_type}}

      not is_boolean(redacted) ->
        {:error, {:invalid_artifact_attributes, :redacted}}

      true ->
        {:ok, %{media_type: media_type, redacted: redacted}}
    end
  end

  defp cast_metadata(_attrs), do: {:error, {:invalid_artifact_attributes, :not_a_map}}

  defp validate_task_ownership(_goal_id, nil), do: :ok

  defp validate_task_ownership(goal_id, task_id) do
    exists? =
      Repo.one(
        from task in Task, where: task.id == ^task_id and task.goal_id == ^goal_id, select: 1
      ) == 1

    if exists?, do: :ok, else: {:error, {:trusted_reference_not_owned, :task_id}}
  end

  defp validate_artifact_metadata(artifact) do
    cond do
      not valid_sha?(artifact.sha256) ->
        {:error, {:artifact_invalid_metadata, :sha256}}

      not is_integer(artifact.byte_size) or artifact.byte_size < 0 ->
        {:error, {:artifact_invalid_metadata, :byte_size}}

      not is_binary(artifact.media_type) or String.trim(artifact.media_type) == "" ->
        {:error, {:artifact_invalid_metadata, :media_type}}

      not is_boolean(artifact.redacted) ->
        {:error, {:artifact_invalid_metadata, :redacted}}

      not valid_task_metadata?(artifact) ->
        {:error, {:artifact_invalid_metadata, :task_id}}

      not Artifact.safe_location?(artifact.location) ->
        {:error, {:artifact_unsafe_location, artifact.location}}

      true ->
        :ok
    end
  end

  defp valid_task_metadata?(%Artifact{task_id: nil}), do: true

  defp valid_task_metadata?(%Artifact{task_id: task_id, goal_id: goal_id}) do
    Repo.one(
      from task in Task, where: task.id == ^task_id and task.goal_id == ^goal_id, select: 1
    ) == 1
  end

  defp persist_artifact(artifact) do
    case Repo.insert(Artifact.changeset(artifact, %{})) do
      {:ok, artifact} -> {:ok, artifact}
      {:error, changeset} -> {:error, {:invalid_artifact, changeset}}
    end
  rescue
    error in [Ecto.ConstraintError] -> {:error, {:invalid_artifact, error}}
  end

  defp valid_sha?(value) when is_binary(value), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp valid_sha?(_value), do: false

  defp write_atomically(root, location, bytes) do
    path = Path.join(root, location)

    if not no_symlink_components?(Path.expand(root), path) do
      {:error, {:artifact_unsafe_location, location}}
    else
      case File.read(path) do
        {:ok, ^bytes} -> {:ok, false}
        {:ok, _other} -> {:error, {:artifact_conflict, location}}
        {:error, :enoent} -> write_new_file(root, location, path, bytes)
        {:error, _reason} -> {:error, {:artifact_conflict, location}}
      end
    end
  end

  defp validate_path_components(root, location) do
    if no_symlink_components?(Path.expand(root), Path.join(Path.expand(root), location)) do
      :ok
    else
      {:error, {:artifact_unsafe_location, location}}
    end
  end

  defp write_new_file(_root, location, path, bytes) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      temp = "#{path}.tmp-#{System.unique_integer([:positive, :monotonic])}"

      result =
        try do
          case File.open(temp, [:write, :binary, :exclusive]) do
            {:ok, io} ->
              result =
                try do
                  write_and_sync(io, bytes)
                after
                  _ = File.close(io)
                end

              case result do
                :ok ->
                  case :file.make_link(temp, path) do
                    :ok -> {:ok, true}
                    {:error, :eexist} -> compare_existing(path, location, bytes)
                    {:error, reason} -> {:error, {:artifact_write_failed, reason}}
                  end

                {:error, reason} ->
                  {:error, {:artifact_write_failed, reason}}
              end

            {:error, reason} ->
              {:error, {:artifact_write_failed, reason}}
          end
        rescue
          error -> {:error, {:artifact_write_failed, Exception.message(error)}}
        after
          _ = File.rm(temp)
        end

      result
    else
      {:error, reason} -> {:error, {:artifact_write_failed, reason}}
    end
  end

  defp compare_existing(path, location, bytes) do
    case File.read(path) do
      {:ok, ^bytes} -> {:ok, false}
      _other -> {:error, {:artifact_conflict, location}}
    end
  end

  defp write_and_sync(io, bytes) do
    with :ok <- IO.binwrite(io, bytes), :ok <- :file.sync(io) do
      :ok
    end
  end

  defp verified_path(root, location) do
    if Artifact.safe_location?(location) do
      expanded_root = Path.expand(root)
      path = Path.join(expanded_root, location)

      cond do
        not contained?(expanded_root, path) ->
          {:error, {:artifact_unsafe_location, location}}

        not no_symlink_components?(expanded_root, path) ->
          {:error, {:artifact_unsafe_location, location}}

        true ->
          case File.stat(path) do
            {:ok, _stat} -> {:ok, path}
            {:error, :enoent} -> {:error, :enoent}
            {:error, reason} -> {:error, {:artifact_path_unavailable, reason}}
          end
      end
    else
      {:error, {:artifact_unsafe_location, location}}
    end
  end

  defp contained?(root, path) do
    relative = Path.relative_to(path, root)
    relative not in ["", ".", ".."] and not String.starts_with?(relative, "../")
  end

  defp no_symlink_components?(root, path) do
    case :file.read_link_info(root) do
      {:ok, %File.Stat{type: :symlink}} ->
        false

      {:ok, _root_stat} ->
        relative = Path.relative_to(path, root)

        relative
        |> Path.split()
        |> Enum.with_index(1)
        |> Enum.all?(fn {_component, index} ->
          prefix = relative |> Path.split() |> Enum.take(index) |> Path.join()

          case :file.read_link_info(Path.join(root, prefix)) do
            {:ok, %File.Stat{type: :symlink}} -> false
            {:ok, _stat} -> true
            {:error, :enoent} -> true
            {:error, _reason} -> false
          end
        end)

      {:error, _reason} ->
        false
    end
  end

  defp validate_location(location) do
    if Artifact.safe_location?(location),
      do: :ok,
      else: {:error, {:artifact_unsafe_location, location}}
  end

  defp maybe_remove_created(root, location, true), do: File.rm(Path.join(root, location))
  defp maybe_remove_created(_root, _location, false), do: :ok

  defp enforce_size(bytes, max_size) do
    if byte_size(bytes) <= max_size,
      do: :ok,
      else: {:error, {:artifact_too_large, byte_size(bytes)}}
  end

  defp cast_uuid(value, field) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:invalid_artifact_reference, field}}
    end
  end

  defp cast_optional_uuid(nil, _field), do: {:ok, nil}
  defp cast_optional_uuid(value, field), do: cast_uuid(value, field)

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
