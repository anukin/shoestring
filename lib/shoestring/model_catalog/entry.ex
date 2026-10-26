defmodule Shoestring.ModelCatalog.Entry do
  @moduledoc """
  One model a harness reported (`source: "live"`) or the operator named by
  hand (`"manual"`). `available` is false once a live listing stops reporting
  it; the row stays, so saved agents that name it are never silently changed.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "harness_models" do
    field :provider, :string
    field :model, :string
    field :display_name, :string
    field :efforts, {:array, :string}, default: []
    field :default_effort, :string
    field :harness_default, :boolean, default: false
    field :resolves_to, :string
    field :source, :string
    field :available, :boolean, default: true
    field :first_seen_at, :utc_datetime_usec
    field :fetched_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
