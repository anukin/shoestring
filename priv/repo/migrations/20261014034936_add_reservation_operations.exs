defmodule Shoestring.Repo.Migrations.AddReservationOperations do
  use Ecto.Migration

  def change do
    create table(:cobbler_reservation_operations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :reservation_id,
          references(:cobbler_capacity_reservations, type: :binary_id, on_delete: :restrict),
          null: false

      add :action, :string, null: false
      add :requested_by, :string, null: false

      add :request_event_id,
          references(:trajectory_events, type: :binary_id, on_delete: :restrict), null: false

      add :status, :string, null: false, default: "pending"
      add :result, :map
      timestamps(type: :utc_datetime_usec)
    end
  end
end
