defmodule Shoestring.Cobbler.Intent do
  @moduledoc """
  Durable record of a Cobbler intent within a goal.

  An intent represents an actionable task unit that has been admitted
  and can be claimed for execution under quota and exclusivity constraints.
  Pending intents are inert and inspectable.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ["pending", "active", "needs_user", "completed", "failed", "cancelled"]

  schema "cobbler_intents" do
    field :title, :string
    field :status, :string, default: "pending"
    field :requested_capability, :string
    field :provider_id, :string
    field :account_id, :string
    field :scope, :string
    field :admission_decision_id, :binary_id
    field :proposed_bounds, :map, default: %{}
    field :override, :map
    field :recovery_data, :map
    field :terminal_reason, :string
    field :metadata, :map, default: %{}

    belongs_to :goal, Shoestring.Trajectory.Goal
    belongs_to :task, Shoestring.Trajectory.Task
    has_one :claim, Shoestring.Cobbler.Claim

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Casts and validates intent creation attributes."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(intent, attrs) do
    intent
    |> cast(attrs, [
      :title,
      :status,
      :requested_capability,
      :provider_id,
      :account_id,
      :scope,
      :admission_decision_id,
      :proposed_bounds,
      :override,
      :recovery_data,
      :terminal_reason,
      :metadata
    ])
    |> validate_required([
      :title,
      :status,
      :requested_capability,
      :provider_id,
      :account_id,
      :scope,
      :admission_decision_id,
      :proposed_bounds
    ])
    |> validate_inclusion(:status, @statuses)
  end

  @type t :: %__MODULE__{}
end
