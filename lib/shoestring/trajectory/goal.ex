defmodule Shoestring.Trajectory.Goal do
  @moduledoc """
  The durable aggregate identity for a Shoestring goal.

  `owner_id` is supplied by the authenticated application boundary and is not
  accepted from ordinary user attribute maps.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

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
    if observatory?(goal) do
      goal
      |> change()
      |> add_error(:base, "protected observatory goal cannot be modified")
    else
      goal
      |> cast(attrs, [:title, :description, :status])
      |> validate_required([:title])
      |> validate_length(:title, min: 1, max: 500)
      |> validate_inclusion(:status, ["active", "completed", "archived"])
    end
  end

  @doc "Builds a creation changeset with ownership assigned by the caller."
  @spec create_changeset(t(), Ecto.UUID.t(), map()) :: Ecto.Changeset.t()
  def create_changeset(goal, owner_id, attrs) do
    if owner_id == Shoestring.Harness.Observatory.observatory_owner_id() do
      goal
      |> changeset(attrs)
      |> add_error(:owner_id, "cannot create goal with protected observatory owner")
    else
      goal
      |> changeset(attrs)
      |> put_change(:owner_id, owner_id)
      |> validate_required([:owner_id])
    end
  end

  @doc "Scope for normal user goals that excludes the singleton observatory goal."
  @spec user_goals(Ecto.Queryable.t()) :: Ecto.Query.t()
  def user_goals(query \\ __MODULE__) do
    observatory_id = Shoestring.Harness.Observatory.observatory_goal_id()
    from g in query, where: g.id != ^observatory_id and g.status != "protected"
  end

  @doc "Returns true if the goal is the protected observatory singleton."
  @spec observatory?(t() | Ecto.UUID.t() | nil) :: boolean()
  def observatory?(%__MODULE__{id: id}) when is_binary(id), do: observatory?(id)
  def observatory?(%__MODULE__{status: "protected"}), do: true

  def observatory?(id) when is_binary(id) do
    id == Shoestring.Harness.Observatory.observatory_goal_id()
  end

  def observatory?(_other), do: false

  @type t :: %__MODULE__{}
end
