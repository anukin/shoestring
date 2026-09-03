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
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(goal_or_changeset, attrs) do
    changeset =
      case goal_or_changeset do
        %Ecto.Changeset{} = cs -> cs
        %__MODULE__{} = goal -> change(goal)
      end

    if observatory?(changeset.data) do
      changeset
      |> add_error(:id, "protected observatory goal cannot be modified")
      |> add_error(:base, "protected observatory goal cannot be modified")
    else
      changeset
      |> cast(attrs, [:title, :description, :status])
      |> validate_required([:title])
      |> validate_length(:title, min: 1, max: 500)
      |> validate_inclusion(:status, ["active", "completed", "archived"])
      |> validate_not_observatory_identity()
    end
  end

  @doc "Builds a creation changeset with ownership assigned by the caller."
  @spec create_changeset(t() | Ecto.Changeset.t(), Ecto.UUID.t(), map()) :: Ecto.Changeset.t()
  def create_changeset(goal_or_changeset, owner_id, attrs) do
    goal_or_changeset
    |> changeset(attrs)
    |> put_change(:owner_id, owner_id)
    |> validate_required([:owner_id])
    |> validate_not_observatory_identity()
  end

  defp validate_not_observatory_identity(changeset) do
    observatory_id = Shoestring.Harness.Observatory.observatory_goal_id()
    observatory_owner = Shoestring.Harness.Observatory.observatory_owner_id()
    observatory_status = Shoestring.Harness.Observatory.observatory_status()

    changeset
    |> validate_observatory_id_not_claimed(observatory_id)
    |> validate_field_not_equal(
      :owner_id,
      observatory_owner,
      "cannot create goal with protected observatory owner"
    )
    |> validate_field_not_equal(:status, observatory_status, "cannot use protected status")
  end

  defp validate_observatory_id_not_claimed(changeset, observatory_id) do
    cond do
      get_change(changeset, :id) == observatory_id ->
        add_error(changeset, :id, "cannot use protected observatory goal id")

      (is_nil(changeset.data.id) or changeset.data.__meta__.state == :built) and
          get_field(changeset, :id) == observatory_id ->
        add_error(changeset, :id, "cannot use protected observatory goal id")

      true ->
        changeset
    end
  end

  defp validate_field_not_equal(changeset, field, forbidden_value, message) do
    case get_field(changeset, field) do
      ^forbidden_value -> add_error(changeset, field, message)
      _other -> changeset
    end
  end

  @doc "Scope for normal user goals that excludes the singleton observatory goal."
  @spec user_goals(Ecto.Queryable.t()) :: Ecto.Query.t()
  def user_goals(query \\ __MODULE__) do
    observatory_id = Shoestring.Harness.Observatory.observatory_goal_id()
    observatory_owner = Shoestring.Harness.Observatory.observatory_owner_id()
    observatory_status = Shoestring.Harness.Observatory.observatory_status()

    from g in query,
      where:
        not (g.id == ^observatory_id and g.owner_id == ^observatory_owner and
               g.status == ^observatory_status)
  end

  @doc "Returns true if the goal is the protected observatory singleton."
  @spec observatory?(t() | Ecto.UUID.t() | nil) :: boolean()
  def observatory?(%__MODULE__{id: id, status: "protected"} = goal) do
    id == Shoestring.Harness.Observatory.observatory_goal_id() and
      goal.owner_id in [nil, Shoestring.Harness.Observatory.observatory_owner_id()]
  end

  def observatory?(id) when is_binary(id) do
    id == Shoestring.Harness.Observatory.observatory_goal_id()
  end

  def observatory?(_other), do: false

  @type t :: %__MODULE__{}
end
