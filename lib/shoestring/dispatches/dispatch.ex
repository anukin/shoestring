defmodule Shoestring.Dispatches.Dispatch do
  @moduledoc """
  One task a coordinator handed to Shoestring under a grant. Its goal,
  approved plan and execution are ordinary Shoestring records; this row is
  what ties them to the grant, and the immutable source of the execution
  binding (worker, model, effort and brief).
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "coordinator_dispatches" do
    field :grant_id, :binary_id
    field :session_id, :string
    field :request_id, :string
    field :purpose, :string
    field :provider, :string
    field :model, :string
    field :effort, :string
    field :title, :string
    field :brief, :string
    field :brief_digest, :string
    field :repository_root, :string
    field :base_revision, :string
    field :max_attempts, :integer
    field :max_duration_seconds, :integer
    field :batch_label, :string
    field :batch_size, :integer
    field :goal_id, :binary_id
    field :plan, :map
    field :plan_digest, :string
    field :execution_id, :string
    field :state, :string
    field :error, :string
    timestamps(type: :utc_datetime_usec)
  end
end
