defmodule Shoestring.ApiSpend.Reservation do
  @moduledoc "Durable one-call spend authority. Unresolved calls never release their maximum."
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  schema "api_spend_reservations" do
    belongs_to :goal, Shoestring.Trajectory.Goal
    belongs_to :run, Shoestring.Harness.RunRecord
    field :version, :integer
    field :pricing, :map
    field :monthly_cap_microusd, :integer
    field :maximum_microusd, :integer
    field :reserved_at, :utc_datetime_usec
    field :reserved_month, :string
    field :status, :string
    field :input_tokens, :integer
    field :output_tokens, :integer
    field :reconciled_microusd, :integer
    field :reconciled_at, :utc_datetime_usec
    field :reconciled_month, :string
  end

  def changeset(row, attrs) do
    row
    |> Ecto.Changeset.change(attrs)
    |> Ecto.Changeset.unique_constraint(:id, name: :api_spend_reservations_pkey)
    |> Ecto.Changeset.foreign_key_constraint(:goal_id)
    |> Ecto.Changeset.foreign_key_constraint(:run_id)
    |> Ecto.Changeset.check_constraint(:maximum_microusd, name: :api_spend_amounts_valid)
    |> Ecto.Changeset.check_constraint(:status, name: :api_spend_status_valid)
    |> Ecto.Changeset.check_constraint(:reconciled_microusd, name: :api_spend_settlement_valid)
  end
end
