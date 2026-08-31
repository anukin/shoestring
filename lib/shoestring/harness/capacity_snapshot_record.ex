defmodule Shoestring.Harness.CapacitySnapshotRecord do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "harness_capacity_snapshots" do
    field :contract_version, :integer
    field :capacity_state, :string
    field :observed_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :source_adapter_id, :string
    field :source_method, :string
    field :scope, :string
    field :confidence, :string
    field :support_tier, :string
    field :compatibility_state, :string
    field :extensions, :map
    field :projection_sequence, :integer

    belongs_to :goal, Shoestring.Trajectory.Goal
    belongs_to :run, Shoestring.Harness.RunRecord
    has_many :windows, Shoestring.Harness.CapacityWindowRecord, foreign_key: :snapshot_id

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :contract_version,
      :capacity_state,
      :observed_at,
      :expires_at,
      :source_adapter_id,
      :source_method,
      :scope,
      :confidence,
      :support_tier,
      :compatibility_state,
      :extensions,
      :projection_sequence
    ])
    |> validate_required([
      :id,
      :goal_id,
      :contract_version,
      :capacity_state,
      :observed_at,
      :source_adapter_id,
      :source_method,
      :scope,
      :confidence,
      :support_tier,
      :compatibility_state,
      :extensions,
      :projection_sequence
    ])
    |> validate_number(:contract_version, greater_than: 0)
    |> validate_inclusion(:capacity_state, ["known", "unknown"])
    |> validate_inclusion(:confidence, ["none", "low", "medium", "high"])
    |> validate_inclusion(:support_tier, ["supported", "partial", "unsupported"])
    |> validate_inclusion(:compatibility_state, ["compatible", "degraded", "incompatible"])
    |> foreign_key_constraint(:goal_id)
    |> foreign_key_constraint(:run_id)
    |> check_constraint(:contract_version, name: "harness_capacity_snapshots_version_positive")
    |> check_constraint(:capacity_state, name: "harness_capacity_snapshots_state_valid")
  end

  @type t :: %__MODULE__{}
end
