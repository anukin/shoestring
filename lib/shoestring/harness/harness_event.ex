defmodule Shoestring.Harness.HarnessEvent do
  @moduledoc "A normalized, transcript-free event emitted by a harness session."

  alias Shoestring.Harness.{Contract, Error}

  @version 1
  @kinds [:lifecycle, :output, :tool, :command, :artifact, :capacity, :error, :result]

  @enforce_keys [
    :version,
    :run_id,
    :source_event_id,
    :ordinal,
    :occurred_at,
    :kind,
    :process_id,
    :provider_session_id,
    :artifact_id,
    :capacity_snapshot_id,
    :error,
    :result,
    :extensions
  ]
  defstruct [
    :version,
    :run_id,
    :source_event_id,
    :ordinal,
    :occurred_at,
    :kind,
    :process_id,
    :provider_session_id,
    :artifact_id,
    :capacity_snapshot_id,
    :error,
    :result,
    :extensions
  ]

  @type t :: %__MODULE__{
          version: 1,
          run_id: Ecto.UUID.t(),
          source_event_id: String.t(),
          ordinal: pos_integer(),
          occurred_at: DateTime.t(),
          kind: atom(),
          process_id: String.t() | nil,
          provider_session_id: String.t() | nil,
          artifact_id: Ecto.UUID.t() | nil,
          capacity_snapshot_id: Ecto.UUID.t() | nil,
          error: Error.t() | nil,
          result: %{status: String.t(), artifact_id: Ecto.UUID.t() | nil} | nil,
          extensions: map()
        }

  @spec version() :: 1
  def version, do: @version

  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attrs) when is_map(attrs) do
    with {:ok, version} <- Contract.version(attrs, @version),
         {:ok, run_id} <- attrs |> Contract.required(:run_id) |> then(&uuid_result(&1, :run_id)),
         {:ok, source_event_id} <-
           attrs
           |> Contract.required(:source_event_id)
           |> then(&Contract.text(&1, :source_event_id, max: 500)),
         {:ok, ordinal} <-
           attrs |> Contract.required(:ordinal) |> then(&Contract.positive_integer(&1, :ordinal)),
         {:ok, occurred_at} <-
           attrs |> Contract.required(:occurred_at) |> then(&datetime_result(&1, :occurred_at)),
         {:ok, kind} <-
           attrs |> Contract.required(:kind) |> then(&Contract.enum(&1, :kind, @kinds)),
         {:ok, process_id} <-
           attrs |> Contract.optional(:process_id) |> then(&optional_text(&1, :process_id)),
         {:ok, provider_session_id} <-
           attrs
           |> Contract.optional(:provider_session_id)
           |> then(&optional_text(&1, :provider_session_id)),
         {:ok, artifact_id} <-
           attrs |> Contract.optional(:artifact_id) |> then(&optional_uuid(&1, :artifact_id)),
         {:ok, capacity_snapshot_id} <-
           attrs
           |> Contract.optional(:capacity_snapshot_id)
           |> then(&optional_uuid(&1, :capacity_snapshot_id)),
         {:ok, error} <- attrs |> Contract.optional(:error) |> then(&event_error/1),
         {:ok, result} <- attrs |> Contract.optional(:result) |> then(&result/1),
         {:ok, extensions} <-
           attrs |> Contract.optional(:extensions) |> then(&Contract.extensions/1),
         :ok <- kind_fields(kind, artifact_id, capacity_snapshot_id, error, result) do
      {:ok,
       %__MODULE__{
         version: version,
         run_id: run_id,
         source_event_id: source_event_id,
         ordinal: ordinal,
         occurred_at: occurred_at,
         kind: kind,
         process_id: process_id,
         provider_session_id: provider_session_id,
         artifact_id: artifact_id,
         capacity_snapshot_id: capacity_snapshot_id,
         error: error,
         result: result,
         extensions: extensions
       }}
    end
  end

  def new(_attrs), do: Contract.invalid(:base, "must be an object")

  defp uuid_result({:ok, value}, field), do: Contract.uuid(value, field)
  defp uuid_result(error, _field), do: error
  defp datetime_result({:ok, value}, field), do: Contract.datetime(value, field)
  defp datetime_result(error, _field), do: error
  defp optional_text(nil, _field), do: {:ok, nil}
  defp optional_text({:ok, value}, field), do: optional_text(value, field)
  defp optional_text(value, field), do: Contract.text(value, field, max: 500)
  defp optional_uuid(nil, _field), do: {:ok, nil}
  defp optional_uuid({:ok, value}, field), do: optional_uuid(value, field)
  defp optional_uuid(value, field), do: Contract.uuid(value, field)

  defp event_error(nil), do: {:ok, nil}
  defp event_error({:ok, value}), do: event_error(value)
  defp event_error(%Error{} = error), do: {:ok, error}

  defp event_error(value) when is_map(value) do
    with {:ok, category} <- value |> Contract.required(:category) |> then(&error_category/1),
         {:ok, code} <-
           value |> Contract.required(:code) |> then(&Contract.text(&1, :error_code, max: 100)),
         {:ok, message} <-
           value
           |> Contract.required(:message)
           |> then(&Contract.text(&1, :error_message, max: 500)),
         {:ok, details} <- value |> Contract.optional(:details) |> then(&Contract.extensions/1) do
      {:ok, Error.new(category, code, message, details: details)}
    end
  end

  defp event_error(_value), do: Contract.invalid(:error, "must be an error object")

  defp error_category({:ok, value}), do: error_category(value)

  defp error_category(value) when is_binary(value) do
    case Enum.find(Error.categories(), &(Atom.to_string(&1) == value)) do
      nil -> Contract.invalid(:error_category, "is not recognized")
      category -> {:ok, category}
    end
  end

  defp error_category(value), do: Contract.enum(value, :error_category, Error.categories())

  defp result(nil), do: {:ok, nil}
  defp result({:ok, value}), do: result(value)

  defp result(value) when is_map(value) do
    with {:ok, status} <-
           value
           |> Contract.required(:status)
           |> then(
             &Contract.enum(&1, :result_status, ["accepted", "completed", "failed", "interrupted"])
           ),
         {:ok, artifact_id} <-
           value
           |> Contract.optional(:artifact_id)
           |> then(&optional_uuid(&1, :result_artifact_id)) do
      {:ok, %{status: status, artifact_id: artifact_id}}
    end
  end

  defp result(_value), do: Contract.invalid(:result, "must be an object")

  defp kind_fields(:artifact, nil, _snapshot_id, _error, _result),
    do: Contract.invalid(:artifact_id, "is required for artifact events")

  defp kind_fields(:capacity, _artifact_id, nil, _error, _result),
    do: Contract.invalid(:capacity_snapshot_id, "is required for capacity events")

  defp kind_fields(:error, _artifact_id, _snapshot_id, nil, _result),
    do: Contract.invalid(:error, "is required for error events")

  defp kind_fields(:result, _artifact_id, _snapshot_id, _error, nil),
    do: Contract.invalid(:result, "is required for result events")

  defp kind_fields(_kind, _artifact_id, _snapshot_id, _error, _result), do: :ok
end
