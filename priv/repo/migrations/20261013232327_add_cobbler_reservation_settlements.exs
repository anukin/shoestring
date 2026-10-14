defmodule Shoestring.Repo.Migrations.AddCobblerReservationSettlements do
  use Ecto.Migration

  def change do
    create table(:cobbler_reservation_settlements, primary_key: false) do
      add :reservation_id,
          references(:cobbler_capacity_reservations, type: :binary_id, on_delete: :restrict),
          primary_key: true

      add :kind, :string,
        null: false,
        check: %{
          name: "cobbler_reservation_settlement_kind_valid",
          expr: "kind IN ('consumed_closed', 'released')"
        }

      add :evidence, :map, null: false
      add :settled_at, :utc_datetime_usec, null: false
    end
  end
end
