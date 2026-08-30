defmodule Shoestring.Trajectory.EventRegistry do
  @moduledoc """
  Versioned validation registry for canonical trajectory event payloads.

  A later milestone can add a new `{type, version}` entry here with its own
  payload schema and an explicit upcaster, without changing stored history.
  """

  import Ecto.Changeset

  alias Shoestring.Trajectory.EventEnvelope

  @payload_schemas %{
    "goal.created" => %{
      1 => %{required: [:title], optional: [:description], uuid_fields: []}
    },
    "task.created" => %{
      1 => %{required: [:task_id, :title], optional: [:description], uuid_fields: [:task_id]}
    },
    "decision.recorded" => %{
      1 => %{required: [:decision], optional: [:rationale], uuid_fields: []}
    },
    "task.completed" => %{
      1 => %{required: [:task_id], optional: [:result], uuid_fields: [:task_id]}
    }
  }

  @doc "Lists the exact event type/version pairs supported by this registry."
  @spec registered_types() :: [{String.t(), pos_integer()}]
  def registered_types do
    @payload_schemas
    |> Enum.flat_map(fn {type, versions} ->
      Enum.map(versions, fn {version, _schema} -> {type, version} end)
    end)
    |> Enum.sort()
  end

  @doc "Validates an envelope and then validates its registered payload schema."
  @spec validate(map()) ::
          {:ok, %{envelope: EventEnvelope.t(), payload: map()}}
          | {:error, {:invalid_envelope, Ecto.Changeset.t()}}
          | {:error, {:invalid_payload, String.t(), pos_integer(), Ecto.Changeset.t()}}
          | {:error, {:unknown_event_type, term()}}
          | {:error, {:unknown_event_version, term(), term()}}
  def validate(attrs) do
    case EventEnvelope.validate(attrs) do
      {:ok, envelope} ->
        case validate_payload(envelope.type, envelope.schema_version, envelope.payload) do
          {:ok, payload} -> {:ok, %{envelope: envelope, payload: payload}}
          error -> error
        end

      {:error, changeset} ->
        {:error, {:invalid_envelope, changeset}}
    end
  end

  @doc "Validates one payload against the exact registered type and version."
  @spec validate_payload(String.t(), pos_integer(), map()) ::
          {:ok, map()}
          | {:error, {:invalid_payload, String.t(), pos_integer(), Ecto.Changeset.t()}}
          | {:error, {:unknown_event_type, term()}}
          | {:error, {:unknown_event_version, term(), term()}}
  def validate_payload(type, version, payload) do
    case Map.fetch(@payload_schemas, type) do
      :error ->
        {:error, {:unknown_event_type, type}}

      {:ok, versions} ->
        case Map.fetch(versions, version) do
          :error ->
            {:error, {:unknown_event_version, type, version}}

          {:ok, schema} ->
            validate_payload_schema(type, version, schema, payload)
        end
    end
  end

  defp validate_payload_schema(type, version, schema, payload) when is_map(payload) do
    fields = schema.required ++ schema.optional
    allowed_keys = Enum.map(fields, &Atom.to_string/1)
    unknown_keys = Map.keys(payload) -- allowed_keys

    changeset =
      {%{}, Enum.into(fields, %{}, &{&1, :string})}
      |> cast(payload, fields)
      |> validate_required(schema.required)
      |> validate_uuid_fields(schema.uuid_fields)

    changeset =
      if unknown_keys == [] do
        changeset
      else
        add_error(changeset, :base, "contains unknown fields")
      end

    if changeset.valid? do
      {:ok, Map.take(payload, allowed_keys)}
    else
      {:error, {:invalid_payload, type, version, changeset}}
    end
  end

  defp validate_payload_schema(type, version, _schema, _payload) do
    changeset = change(%{}) |> add_error(:base, "must be a JSON-compatible object")
    {:error, {:invalid_payload, type, version, changeset}}
  end

  defp validate_uuid_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      validate_change(changeset, field, fn ^field, value ->
        case Ecto.UUID.cast(value) do
          {:ok, _uuid} -> []
          :error -> [{field, "must be a UUID"}]
        end
      end)
    end)
  end
end
