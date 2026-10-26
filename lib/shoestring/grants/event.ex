defmodule Shoestring.Grants.Event do
  @moduledoc "One append-only entry in a grant's history: created, extended, revoked or unread usage used."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "coordinator_grant_events" do
    field :grant_id, :binary_id
    field :kind, :string
    field :actor, :string
    field :payload, :map
    field :occurred_at, :utc_datetime_usec
  end
end
