defmodule Shoestring.Harness.CheckpointArtifactReference do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  schema "harness_checkpoint_artifact_references" do
    belongs_to :checkpoint, Shoestring.Harness.CheckpointRecord
    belongs_to :artifact, Shoestring.Trajectory.Artifact
  end

  @spec changeset(t(), Ecto.UUID.t(), Ecto.UUID.t()) :: Ecto.Changeset.t()
  def changeset(reference, checkpoint_id, artifact_id) do
    reference
    |> cast(%{}, [])
    |> put_change(:checkpoint_id, checkpoint_id)
    |> put_change(:artifact_id, artifact_id)
    |> validate_required([:checkpoint_id, :artifact_id])
    |> foreign_key_constraint(:checkpoint_id)
    |> foreign_key_constraint(:artifact_id)
    |> unique_constraint([:checkpoint_id, :artifact_id])
  end

  @type t :: %__MODULE__{}
end
