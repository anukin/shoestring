defmodule Shoestring.Trajectory.Goal do
  @moduledoc """
  The durable aggregate identity for a Shoestring goal.

  `owner_id` is supplied by the authenticated application boundary and is not
  accepted from ordinary user attribute maps.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "goals" do
    field :owner_id, :binary_id
    field :title, :string
    field :description, :string
    field :status, :string, default: "active"

    has_many :tasks, Shoestring.Trajectory.Task
    has_many :trajectory_events, Shoestring.Trajectory.TrajectoryEvent
    has_many :artifacts, Shoestring.Trajectory.Artifact
    has_many :projector_positions, Shoestring.Trajectory.ProjectorPosition

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Casts user-editable goal attributes without accepting identity fields."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(goal, attrs) do
    goal
    |> cast(attrs, [:title, :description, :status])
    |> validate_required([:title])
    |> validate_length(:title, min: 1, max: 500)
    |> validate_inclusion(:status, ["active", "completed", "archived"])
  end

  @doc "Builds a creation changeset with ownership assigned by the caller."
  @spec create_changeset(t(), Ecto.UUID.t(), map()) :: Ecto.Changeset.t()
  def create_changeset(goal, owner_id, attrs) do
    goal
    |> changeset(attrs)
    |> put_change(:owner_id, owner_id)
    |> validate_required([:owner_id])
  end

  @type t :: %__MODULE__{}
end
