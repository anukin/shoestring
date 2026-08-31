defmodule Shoestring.Harness.ExecutionLeaseRecord do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "harness_execution_leases" do
    field :contract_version, :integer
    field :response_reserve, :integer
    field :tool_reserve, :integer
    field :response_budget, :integer
    field :tool_budget, :integer
    field :deadline, :utc_datetime_usec
    field :checkpoint_cadence, :integer
    field :renewal_state, :string
    field :status, :string, default: "proposed"
    field :extensions, :map
    field :projection_sequence, :integer

    belongs_to :goal, Shoestring.Trajectory.Goal
    belongs_to :run, Shoestring.Harness.RunRecord

    belongs_to :admitted_snapshot, Shoestring.Harness.CapacitySnapshotRecord,
      foreign_key: :admitted_snapshot_id

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(lease, attrs) do
    lease
    |> cast(attrs, [
      :contract_version,
      :response_reserve,
      :tool_reserve,
      :response_budget,
      :tool_budget,
      :deadline,
      :checkpoint_cadence,
      :renewal_state,
      :status,
      :extensions,
      :projection_sequence,
      :updated_at
    ])
    |> validate_required([
      :id,
      :goal_id,
      :run_id,
      :admitted_snapshot_id,
      :contract_version,
      :response_reserve,
      :tool_reserve,
      :response_budget,
      :tool_budget,
      :deadline,
      :checkpoint_cadence,
      :renewal_state,
      :status,
      :extensions,
      :projection_sequence
    ])
    |> validate_number(:contract_version, greater_than: 0)
    |> validate_number(:response_reserve, greater_than_or_equal_to: 0)
    |> validate_number(:tool_reserve, greater_than_or_equal_to: 0)
    |> validate_number(:response_budget, greater_than: 0)
    |> validate_number(:tool_budget, greater_than: 0)
    |> validate_number(:checkpoint_cadence, greater_than: 0)
    |> validate_inclusion(:renewal_state, [
      "none",
      "eligible",
      "due",
      "renewed",
      "expired",
      "revoked"
    ])
    |> validate_inclusion(:status, [
      "proposed",
      "granted",
      "active",
      "renewal_due",
      "renewed",
      "expired",
      "revoked",
      "checkpoint_required"
    ])
    |> foreign_key_constraint(:goal_id)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:admitted_snapshot_id)
    |> check_constraint(:contract_version, name: "harness_execution_leases_version_positive")
    |> check_constraint(:renewal_state, name: "harness_execution_leases_renewal_state_valid")
    |> check_constraint(:status, name: "harness_execution_leases_status_valid")
  end

  @type t :: %__MODULE__{}
end
