defmodule Shoestring.Repo.Migrations.AddCobblerCapacityReservations do
  use Ecto.Migration

  def change do
    create table(:cobbler_capacity_reservations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :goal_id, references(:goals, type: :binary_id, on_delete: :restrict), null: false

      add :admission_event_id,
          references(:trajectory_events, type: :binary_id, on_delete: :restrict), null: false

      add :execution_id, :binary_id, null: false
      add :plan_task_id, :string, null: false

      add :attempt, :integer,
        null: false,
        check: %{name: "cobbler_reservation_attempt_positive", expr: "attempt > 0"}

      add :run_id, :binary_id, null: false
      add :provider_id, :string, null: false
      add :scope, :string, null: false
      add :snapshot_id, :binary_id, null: false

      add :observation_age_seconds, :integer,
        check: %{
          name: "cobbler_reservation_age_nonnegative",
          expr: "observation_age_seconds IS NULL OR observation_age_seconds >= 0"
        }

      add :admission_policy, :map, null: false
      add :concurrency_policy, :map, null: false

      add :units, :integer,
        null: false,
        check: %{name: "cobbler_reservation_units_positive", expr: "units > 0"}

      add :lease_bounds, :map, null: false
      add :reconcile_after, :utc_datetime_usec, null: false

      add :status, :string,
        null: false,
        default: "held",
        check: %{
          name: "cobbler_reservation_status_valid",
          expr: "status IN ('held', 'reconciliation_required')"
        }

      add :reconciliation_reason, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:cobbler_capacity_reservations, [:run_id])
    create unique_index(:cobbler_capacity_reservations, [:admission_event_id])

    create unique_index(
             :cobbler_capacity_reservations,
             [:goal_id, :execution_id, :plan_task_id, :attempt]
           )

    create index(:cobbler_capacity_reservations, [:provider_id, :scope])
  end
end
