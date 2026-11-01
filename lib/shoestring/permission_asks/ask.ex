defmodule Shoestring.PermissionAsks.Ask do
  @moduledoc "One worker request for more than its sandbox allows, and its decision."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "permission_asks" do
    field :goal_id, :binary_id
    field :run_id, :string
    field :dispatch_id, :binary_id
    field :session_id, :string
    field :agent, :string
    field :provider, :string
    field :command, :string
    field :reason, :string
    field :cwd, :string
    # The command a rule for its agent would match; nil when none may.
    field :rule_key, :string
    # pending | allowed | denied | expired
    field :state, :string, default: "pending"
    field :note, :string
    field :decided_by, :string
    field :decided_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
