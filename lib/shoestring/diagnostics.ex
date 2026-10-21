defmodule Shoestring.Diagnostics do
  @moduledoc "Explicit bounded diagnostic preview and digest-confirmed private export. No upload or cleanup."
  import Ecto.Query
  alias Shoestring.Diagnostics.{Bundle, Runtime}
  alias Shoestring.Repo
  alias Shoestring.Trajectory.TrajectoryEvent

  @doc "Preview the complete sanitized bundle, including its exact export digest."
  def preview(opts \\ []) do
    with {:ok, limit, goal} <- selection(opts) do
      Repo.transaction(fn ->
        base =
          if goal,
            do: from(e in TrajectoryEvent, where: e.goal_id == ^goal),
            else: TrajectoryEvent

        recent =
          from e in base,
            order_by: [desc: e.occurred_at, desc: e.id],
            limit: ^limit,
            select:
              struct(e, [
                :id,
                :goal_id,
                :run_id,
                :sequence,
                :occurred_at,
                :type,
                :schema_version,
                :payload
              ])

        source_bytes =
          Repo.one(
            from e in subquery(recent),
              select:
                sum(
                  fragment("length(CAST(? AS BLOB)) + length(CAST(? AS BLOB))", e.payload, e.type)
                )
          ) || 0

        if source_bytes > Bundle.max_source_bytes(), do: Repo.rollback(:diagnostic_source_limit)

        total = Repo.aggregate(base, :count)
        events = Repo.all(recent)

        case Bundle.build(events, Runtime.collect(), total) do
          {:ok, bundle} -> Bundle.preview(bundle)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc "Regenerate the preview and export only when its exact bytes match the operator's confirmation."
  def export(path, confirmation, opts \\ []) do
    with true <- is_binary(confirmation) and Regex.match?(~r/\A[0-9a-f]{64}\z/, confirmation),
         {:ok, preview} <- preview(opts),
         true <- confirmation == preview["confirmation_sha256"],
         :ok <- write_private(path, Bundle.encode(preview["bundle"])) do
      {:ok, Map.drop(preview, ["bundle"])}
    else
      false -> {:error, :diagnostic_confirmation_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp selection(opts) do
    limit = Keyword.get(opts, :limit, Bundle.max_events())
    goal = Keyword.get(opts, :goal)

    cond do
      Keyword.keys(opts) -- [:limit, :goal] != [] ->
        {:error, :invalid_diagnostic_selection}

      length(opts) != length(Enum.uniq(Keyword.keys(opts))) ->
        {:error, :invalid_diagnostic_selection}

      not is_integer(limit) or limit < 1 or limit > Bundle.max_events() ->
        {:error, :invalid_diagnostic_selection}

      is_nil(goal) ->
        {:ok, limit, nil}

      true ->
        case Ecto.UUID.cast(goal) do
          {:ok, goal} -> {:ok, limit, goal}
          :error -> {:error, :invalid_diagnostic_selection}
        end
    end
  end

  defp write_private(path, bytes) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, file} ->
        try do
          with :ok <- File.chmod(path, 0o600),
               :ok <- IO.binwrite(file, bytes),
               :ok <- :file.sync(file) do
            :ok
          else
            _ -> {:error, :diagnostic_write_failed}
          end
        after
          File.close(file)
        end

      {:error, :eexist} ->
        {:error, :diagnostic_export_exists}

      {:error, _} ->
        {:error, :diagnostic_write_failed}
    end
  end
end
