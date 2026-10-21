defmodule Shoestring.Measurement do
  @moduledoc "Explicit local measurement rebuild, report, export and derived-data deletion."
  import Ecto.Query
  alias Shoestring.Measurement.Dataset
  alias Shoestring.Repo
  alias Shoestring.Trajectory.TrajectoryEvent

  @max_bytes 32 * 1024 * 1024

  @doc "Read one consistent database snapshot without starting providers or projectors."
  def snapshot(opts \\ []) do
    Repo.transaction(fn ->
      payload_bytes =
        Repo.one(
          from e in TrajectoryEvent, select: sum(fragment("length(CAST(? AS BLOB))", e.payload))
        ) || 0

      if payload_bytes > @max_bytes, do: Repo.rollback(:measurement_source_size_limit)

      events =
        Repo.all(
          from e in TrajectoryEvent,
            order_by: [e.goal_id, e.sequence],
            limit: ^(Dataset.max_events() + 1)
        )

      case Dataset.build(events, opts) do
        {:ok, dataset} -> dataset
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Explicitly replace only the disposable measurement cache. History is untouched."
  def rebuild(opts \\ []) do
    with {:ok, dataset} <- snapshot(opts),
         :ok <- File.mkdir_p(Path.dirname(cache_path())),
         :ok <- replace_cache(Dataset.encode(dataset)) do
      {:ok, summary(dataset)}
    end
  end

  def report(opts \\ []) do
    with {:ok, dataset} <- snapshot(opts), do: {:ok, summary(dataset)}
  end

  @doc "Export freshly derived data, refusing to overwrite any existing file."
  def export(path, opts \\ []) do
    with {:ok, dataset} <- snapshot(opts),
         :ok <- write_exclusive(path, Dataset.encode(dataset)) do
      {:ok, summary(dataset)}
    end
  end

  @doc "Delete only the fixed derived cache after explicit confirmation; never canonical history."
  def delete_cache(confirm: true) do
    case File.rm(cache_path()) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _} -> {:error, :measurement_cache_delete_failed}
    end
  end

  def delete_cache(_), do: {:error, :confirmation_required}

  def cache_path, do: Path.join([Shoestring.State.root(), "measurements", "dataset-v1.json"])

  def summary(dataset) do
    dataset
    |> Map.take(
      ~w(dataset_version extractor_version split_at source_digest source_event_count quality)
    )
    |> Map.put("dataset_digest", Dataset.digest(dataset))
  end

  defp replace_cache(bytes) do
    temporary = cache_path() <> ".rebuild-" <> Ecto.UUID.generate()

    with :ok <- write_exclusive(temporary, bytes) do
      case File.rename(temporary, cache_path()) do
        :ok -> :ok
        {:error, _} -> {:error, :measurement_cache_replace_failed}
      end
    end
  end

  defp write_exclusive(_path, bytes) when byte_size(bytes) > @max_bytes,
    do: {:error, :measurement_export_size_limit}

  defp write_exclusive(path, bytes) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, file} ->
        try do
          with :ok <- File.chmod(path, 0o600),
               :ok <- IO.binwrite(file, bytes),
               :ok <- :file.sync(file) do
            :ok
          else
            _ -> {:error, :measurement_write_failed}
          end
        after
          File.close(file)
        end

      {:error, :eexist} ->
        {:error, :export_already_exists}

      {:error, _} ->
        {:error, :measurement_write_failed}
    end
  end
end
