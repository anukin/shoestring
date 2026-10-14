defmodule Shoestring.Cobbler.ReservationOperationRecord do
  @moduledoc "Durable operator recovery request; canonical events bind its action and result."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: false}
  schema "cobbler_reservation_operations" do
    field :reservation_id, :binary_id
    field :action, :string
    field :requested_by, :string
    field :request_event_id, :binary_id
    field :status, :string, default: "pending"
    field :result, :map
    timestamps(type: :utc_datetime_usec)
  end

  def request(attrs) do
    %__MODULE__{}
    |> change(attrs)
    |> validate_required([:id, :reservation_id, :action, :requested_by, :request_event_id])
    |> validate_inclusion(:action, ["reconcile", "cancel-unstarted"])
    |> unique_constraint(:id, name: "cobbler_reservation_operations_pkey")
    |> foreign_key_constraint(:reservation_id)
    |> foreign_key_constraint(:request_event_id)
  end
end
