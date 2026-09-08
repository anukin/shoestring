defmodule Shoestring.Cobbler.TaskClaimRecord do
  @moduledoc """
  The durable global MVP task claim.

  Exclusivity is enforced by SQLite, never by counting: a partial unique
  index on `scope` restricted to `status = 'active'` admits at most one
  active claim row. A competing claim transaction loses on that index during
  its own immediate write transaction, so there is no count-then-act window.

  A claim is never released by a timer, by staleness, or by an ambiguous
  restart. There is no expiry column and no automatic release path: the only
  way an active claim leaves the `active` state is an explicit release
  command recorded against the owning goal.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cobbler_task_claims" do
    field :scope, :string, default: "global"
    field :status, :string, default: "active"
    field :command_id, :string
    field :intent, :string
    field :provider_id, :string
    field :admission_decision_id, :string
    field :admission_event_id, :binary_id
    field :released_by_command_id, :string
    field :release_reason, :string
    field :released_at, :utc_datetime_usec

    belongs_to :goal, Shoestring.Trajectory.Goal

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Builds the single active global claim created by an admitted command."
  @spec acquire_changeset(
          Ecto.UUID.t(),
          String.t(),
          map(),
          String.t(),
          Ecto.UUID.t(),
          DateTime.t()
        ) :: Ecto.Changeset.t()
  def acquire_changeset(goal_id, command_id, claim_fields, decision_id, admission_event_id, now) do
    %__MODULE__{}
    |> cast(%{}, [])
    |> put_change(:scope, "global")
    |> put_change(:status, "active")
    |> put_change(:goal_id, goal_id)
    |> put_change(:command_id, command_id)
    |> put_change(:intent, claim_fields.intent)
    |> put_change(:provider_id, claim_fields.provider_id)
    |> put_change(:admission_decision_id, decision_id)
    |> put_change(:admission_event_id, admission_event_id)
    |> put_change(:inserted_at, now)
    |> put_change(:updated_at, now)
    |> foreign_key_constraint(:goal_id)
    |> unique_constraint(:scope, name: "cobbler_task_claims_scope_index")
    |> check_constraint(:scope, name: "cobbler_task_claims_scope_global")
    |> check_constraint(:status, name: "cobbler_task_claims_status_valid")
    |> check_constraint(:command_id, name: "cobbler_task_claims_command_id_present")
    |> check_constraint(:intent, name: "cobbler_task_claims_intent_present")
    |> check_constraint(:provider_id, name: "cobbler_task_claims_provider_id_present")
    |> check_constraint(:released_at, name: "cobbler_task_claims_release_fields_consistent")
    |> check_constraint(:released_by_command_id,
      name: "cobbler_task_claims_release_attribution_present"
    )
  end

  @doc "Marks the claim released by an explicit release command."
  @spec release_changeset(t(), String.t(), String.t(), DateTime.t()) :: Ecto.Changeset.t()
  def release_changeset(
        %__MODULE__{status: "active"} = claim,
        released_by_command_id,
        reason,
        now
      ) do
    claim
    |> cast(%{}, [])
    |> put_change(:status, "released")
    |> put_change(:released_by_command_id, released_by_command_id)
    |> put_change(:release_reason, reason)
    |> put_change(:released_at, now)
    |> put_change(:updated_at, now)
    |> unique_constraint(:scope, name: "cobbler_task_claims_scope_index")
    |> check_constraint(:status, name: "cobbler_task_claims_status_valid")
    |> check_constraint(:released_at, name: "cobbler_task_claims_release_fields_consistent")
    |> check_constraint(:released_by_command_id,
      name: "cobbler_task_claims_release_attribution_present"
    )
  end

  @type t :: %__MODULE__{}
end
