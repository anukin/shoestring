defmodule Shoestring.Trajectory.Task do
  @moduledoc "A durable task belonging to one goal."

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "tasks" do
    field :title, :string
    field :description, :string
    field :status, :string, default: "pending"
    field :position, :integer, default: 0

    belongs_to :goal, Shoestring.Trajectory.Goal
    has_many :trajectory_events, Shoestring.Trajectory.TrajectoryEvent
    has_many :artifacts, Shoestring.Trajectory.Artifact

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Casts task attributes without accepting the programmatic goal id."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(task, attrs) do
    task
    |> cast(attrs, [:title, :description, :status, :position])
    |> validate_required([:title])
    |> validate_length(:title, min: 1, max: 500)
    |> validate_inclusion(:status, ["pending", "in_progress", "completed", "blocked"])
    |> validate_number(:position, greater_than_or_equal_to: 0)
  end

  @type t :: %__MODULE__{}
end
