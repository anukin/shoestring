defmodule Shoestring.Trajectory.TrajectoryEvent do
  @moduledoc """
  The append-only canonical event envelope persisted for a goal.

  Identity, ownership, ordering, and relationship fields are assigned by the
  application boundary and intentionally excluded from the ordinary changeset
  cast list.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Shoestring.Trajectory.EventValidation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "trajectory_events" do
    field :run_id, :binary_id
    field :sequence, :integer
    field :parent_event_id, :binary_id
    field :type, :string
    field :actor, :string
    field :occurred_at, :utc_datetime_usec
    field :schema_version, :integer
    field :payload, :map
    field :idempotency_key, :string

    belongs_to :goal, Shoestring.Trajectory.Goal
    belongs_to :task, Shoestring.Trajectory.Task
    belongs_to :parent_event, __MODULE__, foreign_key: :parent_event_id, define_field: false

    has_many :child_events, __MODULE__, foreign_key: :parent_event_id
  end

  @doc "Casts the envelope fields while keeping programmatic IDs and ordering out."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:type, :actor, :occurred_at, :schema_version, :payload, :idempotency_key])
    |> validate_required([
      :goal_id,
      :sequence,
      :type,
      :actor,
      :occurred_at,
      :schema_version,
      :payload
    ])
    |> validate_length(:type, min: 1, max: 200)
    |> validate_length(:actor, min: 1, max: 200)
    |> validate_number(:sequence, greater_than: 0)
    |> validate_number(:schema_version, greater_than: 0)
    |> validate_change(:payload, &EventValidation.validate_json_payload/2)
    |> validate_change(:idempotency_key, &EventValidation.validate_idempotency_key/2)
    |> check_constraint(:sequence,
      name: "trajectory_events_sequence_positive",
      message: "must be greater than 0"
    )
    |> check_constraint(:schema_version,
      name: "trajectory_events_schema_version_positive",
      message: "must be greater than 0"
    )
    |> check_constraint(:type, name: "trajectory_events_type_present", message: "can't be blank")
    |> check_constraint(:actor,
      name: "trajectory_events_actor_present",
      message: "can't be blank"
    )
    |> check_constraint(:idempotency_key,
      name: "trajectory_events_idempotency_key_present",
      message: "can't be blank when present"
    )
    |> unique_constraint(:sequence, name: "trajectory_events_goal_id_sequence_index")
    |> unique_constraint(:idempotency_key,
      name: "trajectory_events_goal_id_idempotency_key_index"
    )
  end

  @type t :: %__MODULE__{}
end
