defmodule Shoestring.Grants.Grant do
  @moduledoc "A person's allowance for one coordinator session. See `Shoestring.Grants`."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "coordinator_grants" do
    field :session_id, :string
    field :granted_by, :string
    field :repository_root, :string
    field :models, {:array, :string}, default: []
    field :purposes, {:array, :string}, default: []
    field :max_dispatches, :integer
    field :max_parallel, :integer
    field :max_total_seconds, :integer
    field :max_dispatch_seconds, :integer
    field :unread_usage, :integer, default: 0
    field :unread_usage_used, :integer, default: 0
    field :limits_revision, :integer, default: 1
    field :revoked_at, :utc_datetime_usec
    field :revoked_by, :string
    timestamps(type: :utc_datetime_usec)
  end
end
