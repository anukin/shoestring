defmodule Shoestring.Trajectory.EventEnvelope do
  @moduledoc """
  Validation for the common, version-independent event envelope.

  This full envelope is the trusted persisted/replay representation. Raw
  append callers use `Shoestring.Trajectory.AppendInput`, which deliberately
  omits identity, ownership, relationship, and sequence fields.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Shoestring.Trajectory.EventValidation

  @primary_key false

  embedded_schema do
    field :id, :binary_id
    field :goal_id, :binary_id
    field :task_id, :binary_id
    field :run_id, :binary_id
    field :sequence, :integer
    field :parent_event_id, :binary_id
    field :type, :string
    field :actor, :string
    field :occurred_at, :utc_datetime_usec
    field :schema_version, :integer
    field :payload, :map
    field :idempotency_key, :string
  end

  @required_fields [
    :goal_id,
    :sequence,
    :type,
    :actor,
    :occurred_at,
    :schema_version,
    :payload
  ]

  @doc "Validates only the common envelope, without consulting the event registry."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(envelope, attrs) when is_map(attrs) do
    envelope
    |> cast(attrs, [
      :id,
      :goal_id,
      :task_id,
      :run_id,
      :sequence,
      :parent_event_id,
      :type,
      :actor,
      :occurred_at,
      :schema_version,
      :payload,
      :idempotency_key
    ])
    |> validate_required(@required_fields)
    |> validate_length(:type, min: 1, max: 200)
    |> validate_length(:actor, min: 1, max: 200)
    |> validate_number(:sequence, greater_than: 0)
    |> validate_number(:schema_version, greater_than: 0)
    |> validate_change(:payload, &EventValidation.validate_json_payload/2)
    |> validate_change(:idempotency_key, &EventValidation.validate_idempotency_key/2)
  end

  def changeset(envelope, _attrs) do
    change(envelope)
    |> add_error(:base, "must be a map")
  end

  @doc "Returns a validated envelope struct or its changeset errors."
  @spec validate(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def validate(attrs) when is_map(attrs) do
    changeset = changeset(%__MODULE__{}, attrs)

    if changeset.valid? do
      {:ok, apply_changes(changeset)}
    else
      {:error, changeset}
    end
  end

  def validate(_attrs) do
    {:error, change(%__MODULE__{}) |> add_error(:base, "must be a map")}
  end

  @type t :: %__MODULE__{}
end
