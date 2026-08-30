defmodule Shoestring.Trajectory.ProjectorPosition do
  @moduledoc "Durable replay position for one versioned projector and goal."

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "projector_positions" do
    field :projector, :string
    field :version, :integer
    field :last_sequence, :integer, default: 0

    belongs_to :goal, Shoestring.Trajectory.Goal

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Casts projector position values without accepting the programmatic goal id."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(position, attrs) do
    position
    |> cast(attrs, [:projector, :version, :last_sequence])
    |> validate_required([:projector, :version, :last_sequence])
    |> validate_length(:projector, min: 1, max: 200)
    |> validate_number(:version, greater_than: 0)
    |> validate_number(:last_sequence, greater_than_or_equal_to: 0)
    |> unique_constraint([:goal_id, :projector])
  end

  @type t :: %__MODULE__{}
end
