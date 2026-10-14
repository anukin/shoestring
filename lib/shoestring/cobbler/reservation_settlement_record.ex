defmodule Shoestring.Cobbler.ReservationSettlementRecord do
  @moduledoc "Append-only settlement evidence; original reservation ownership is never erased."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:reservation_id, :binary_id, autogenerate: false}
  schema "cobbler_reservation_settlements" do
    field :kind, :string
    field :evidence, :map
    field :settled_at, :utc_datetime_usec
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> change(attrs)
    |> validate_required([:reservation_id, :kind, :evidence, :settled_at])
    |> validate_inclusion(:kind, ["consumed_closed", "released"])
    |> foreign_key_constraint(:reservation_id)
    |> unique_constraint(:reservation_id)
    |> check_constraint(:kind, name: "cobbler_reservation_settlement_kind_valid")
  end
end
