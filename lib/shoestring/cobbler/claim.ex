defmodule Shoestring.Cobbler.Claim do
  @moduledoc """
  Durable exclusive task claim for Milestone 05 MVP.

  Enforces at the SQLite database layer that at most ONE implementation task
  can be active globally at any time, recording the account, provider, and
  candidate identity holding the slot.

  A claim is never released by timers, heartbeats, quiet timeouts, or restarts;
  it is only released upon explicit terminal lifecycle transition (completed,
  failed, cancelled).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ["active", "released"]

  schema "cobbler_claims" do
    field :claim_slot, :string, default: "global_active"
    field :active_slot, :string
    field :command_id, :string
    field :provider_id, :string
    field :account_id, :string
    field :scope, :string
    field :status, :string, default: "active"
    field :claimed_at, :utc_datetime_usec
    field :released_at, :utc_datetime_usec
    field :release_reason, :string
    field :metadata, :map, default: %{}

    belongs_to :goal, Shoestring.Trajectory.Goal
    belongs_to :intent, Shoestring.Cobbler.Intent

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Changeset for acquiring a new active claim."
  @spec acquire_changeset(t(), map()) :: Ecto.Changeset.t()
  def acquire_changeset(claim, attrs) do
    claim
    |> cast(attrs, [
      :claim_slot,
      :active_slot,
      :command_id,
      :provider_id,
      :account_id,
      :scope,
      :status,
      :claimed_at,
      :metadata
    ])
    |> validate_required([
      :claim_slot,
      :command_id,
      :provider_id,
      :account_id,
      :scope,
      :status,
      :claimed_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:active_slot, name: :cobbler_claims_active_slot_index)
    |> unique_constraint(:claim_slot, name: :cobbler_claims_singleton_active_index)
    |> unique_constraint(:claim_slot, name: :cobbler_claims_claim_slot_index)
  end

  @doc "Changeset for releasing an active claim upon terminal transition."
  @spec release_changeset(t(), map()) :: Ecto.Changeset.t()
  def release_changeset(claim, attrs) do
    claim
    |> cast(attrs, [:status, :active_slot, :released_at, :release_reason, :metadata])
    |> validate_required([:status, :released_at])
    |> validate_inclusion(:status, ["released"])
  end

  @type t :: %__MODULE__{}
end
