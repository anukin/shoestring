defmodule Shoestring.Cobbler.ReservationRecord do
  @moduledoc "Durable configured allowance ownership; unresolved owners always occupy capacity."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "cobbler_capacity_reservations" do
    belongs_to :goal, Shoestring.Trajectory.Goal
    belongs_to :admission_event, Shoestring.Trajectory.TrajectoryEvent
    field :execution_id, :binary_id
    field :plan_task_id, :string
    field :attempt, :integer
    # Reserved before a run exists; deliberately not a run foreign key.
    field :run_id, :binary_id
    field :provider_id, :string
    field :scope, :string
    field :snapshot_id, :binary_id
    field :observation_age_seconds, :integer
    field :admission_policy, :map
    field :concurrency_policy, :map
    field :units, :integer
    field :lease_bounds, :map
    field :reconcile_after, :utc_datetime_usec
    field :status, :string, default: "held"
    field :reconciliation_reason, :string
    timestamps(type: :utc_datetime_usec)
  end

  def hold_changeset(attrs) do
    %__MODULE__{}
    |> change(attrs)
    |> validate_required([
      :id,
      :goal_id,
      :execution_id,
      :plan_task_id,
      :attempt,
      :run_id,
      :admission_event_id,
      :provider_id,
      :scope,
      :snapshot_id,
      :admission_policy,
      :concurrency_policy,
      :units,
      :lease_bounds,
      :reconcile_after
    ])
    |> foreign_key_constraint(:goal_id)
    |> foreign_key_constraint(:admission_event_id)
    |> unique_constraint(:id, name: "cobbler_capacity_reservations_pkey")
    |> unique_constraint(:run_id)
    |> unique_constraint(:admission_event_id)
    |> unique_constraint([:goal_id, :execution_id, :plan_task_id, :attempt])
  end
end
