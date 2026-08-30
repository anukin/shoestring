defmodule Shoestring.Trajectory.Artifact do
  @moduledoc "Portable metadata for a bounded artifact owned by a goal."

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "artifacts" do
    field :sha256, :string
    field :byte_size, :integer
    field :media_type, :string
    field :location, :string
    field :redacted, :boolean, default: false

    belongs_to :goal, Shoestring.Trajectory.Goal
    belongs_to :task, Shoestring.Trajectory.Task

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Casts artifact metadata without accepting its programmatic owners."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [:sha256, :byte_size, :media_type, :location, :redacted])
    |> validate_required([:sha256, :byte_size, :media_type, :location])
    |> validate_format(:sha256, ~r/\A[0-9a-f]{64}\z/)
    |> validate_number(:byte_size, greater_than_or_equal_to: 0)
    |> validate_change(:location, &validate_location/2)
    |> check_constraint(:byte_size,
      name: "artifacts_byte_size_nonnegative",
      message: "must be greater than or equal to 0"
    )
  end

  defp validate_location(:location, location) do
    path_parts = Path.split(location)

    if Path.type(location) == :absolute or Enum.member?(path_parts, "..") do
      [location: "must be a safe relative path"]
    else
      []
    end
  end

  @type t :: %__MODULE__{}
end
