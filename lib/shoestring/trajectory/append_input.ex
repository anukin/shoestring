defmodule Shoestring.Trajectory.AppendInput do
  @moduledoc """
  The untrusted input accepted by the public append boundary.

  Aggregate identity, event identity, relationship fields, and sequence are
  deliberately absent. The writer creates those trusted fields after routing
  the request to the goal-specific process.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Shoestring.Trajectory.EventValidation

  @primary_key false
  @allowed_fields [:type, :schema_version, :actor, :occurred_at, :payload, :idempotency_key]
  @allowed_string_fields Enum.map(@allowed_fields, &Atom.to_string/1)
  @forbidden_fields ["id", "goal_id", "sequence", "task_id", "run_id", "parent_event_id"]

  embedded_schema do
    field :type, :string
    field :schema_version, :integer
    field :actor, :string
    field :occurred_at, :utc_datetime_usec
    field :payload, :map
    field :idempotency_key, :string
  end

  @doc "Casts only untrusted append fields and rejects trusted-field forgery."
  @spec cast(map()) ::
          {:ok, t()}
          | {:error, {:forbidden_append_fields, [String.t(), ...]}}
          | {:error, {:invalid_append_input, Ecto.Changeset.t()}}
  def cast(attrs) when is_map(attrs) do
    keys = Map.keys(attrs)

    forbidden =
      keys
      |> Enum.filter(&forbidden_key?/1)
      |> Enum.map(&field_name/1)
      |> Enum.uniq()
      |> Enum.sort()

    unknown =
      keys
      |> Enum.reject(&allowed_key?/1)
      |> Enum.map(&field_name/1)
      |> Enum.uniq()
      |> Enum.sort()

    cond do
      forbidden != [] ->
        {:error, {:forbidden_append_fields, forbidden}}

      true ->
        changeset = changeset(%__MODULE__{}, attrs, unknown)

        if changeset.valid? do
          {:ok, apply_changes(changeset)}
        else
          {:error, {:invalid_append_input, changeset}}
        end
    end
  end

  def cast(_attrs) do
    changeset = change(%__MODULE__{}) |> add_error(:base, "must be a map")
    {:error, {:invalid_append_input, changeset}}
  end

  @doc false
  @spec changeset(t(), map(), [String.t()]) :: Ecto.Changeset.t()
  def changeset(input, attrs, unknown_fields \\ []) do
    changeset =
      input
      |> cast(attrs, @allowed_fields)
      |> validate_required([:type, :schema_version, :actor, :payload])
      |> validate_length(:type, min: 1, max: 200)
      |> validate_length(:actor, min: 1, max: 200)
      |> validate_number(:schema_version, greater_than: 0)
      |> validate_change(:payload, &EventValidation.validate_json_payload/2)
      |> validate_change(:idempotency_key, &EventValidation.validate_idempotency_key/2)

    if unknown_fields == [] do
      changeset
    else
      add_error(changeset, :base, "contains unknown fields")
    end
  end

  defp allowed_key?(key), do: key in @allowed_fields or key in @allowed_string_fields

  defp forbidden_key?(key) when is_atom(key), do: Atom.to_string(key) in @forbidden_fields
  defp forbidden_key?(key) when is_binary(key), do: key in @forbidden_fields
  defp forbidden_key?(_key), do: false

  defp field_name(key) when is_atom(key), do: Atom.to_string(key)
  defp field_name(key) when is_binary(key), do: key
  defp field_name(key), do: inspect(key)

  @type t :: %__MODULE__{}
end
