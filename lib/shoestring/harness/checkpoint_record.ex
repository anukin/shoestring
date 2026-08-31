defmodule Shoestring.Harness.CheckpointRecord do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "harness_checkpoints" do
    field :contract_version, :integer
    field :acceptance_contract, :map
    field :repository_state, :map
    field :evidence, :map
    field :decisions, :map
    field :unresolved_issues, :map
    field :next_action, :string
    field :provider_session_id, :string
    field :stop_reason, :string
    field :extensions, :map
    field :projection_sequence, :integer

    belongs_to :goal, Shoestring.Trajectory.Goal
    belongs_to :run, Shoestring.Harness.RunRecord

    has_many :artifact_references, Shoestring.Harness.CheckpointArtifactReference,
      foreign_key: :checkpoint_id

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(checkpoint, attrs) do
    checkpoint
    |> cast(attrs, [
      :contract_version,
      :acceptance_contract,
      :repository_state,
      :evidence,
      :decisions,
      :unresolved_issues,
      :next_action,
      :provider_session_id,
      :stop_reason,
      :extensions,
      :projection_sequence
    ])
    |> validate_required([
      :id,
      :goal_id,
      :run_id,
      :contract_version,
      :acceptance_contract,
      :repository_state,
      :evidence,
      :decisions,
      :unresolved_issues,
      :next_action,
      :stop_reason,
      :extensions,
      :projection_sequence
    ])
    |> validate_number(:contract_version, greater_than: 0)
    |> foreign_key_constraint(:goal_id)
    |> foreign_key_constraint(:run_id)
    |> check_constraint(:contract_version, name: "harness_checkpoints_version_positive")
  end

  @type t :: %__MODULE__{}
end
