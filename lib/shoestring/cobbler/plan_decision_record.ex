defmodule Shoestring.Cobbler.PlanDecisionRecord do
  @moduledoc """
  Durable row for one terminal human decision on one plan revision.

  A decision names the revision, the exact content digest it was taken
  against, who took it, and when. Binding the digest — not just the revision
  number — is what makes a stale approval detectable: an operator who
  approves what their screen showed, after the plan moved on, carries the
  old digest and is refused rather than silently authorizing content they
  never read.

  A unique index on `plan_revision_id` keeps this terminal: one revision,
  one decision. A rejection must carry a bounded reason; an approval may
  carry an optional note.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(approve reject)

  schema "cobbler_plan_decisions" do
    field :decision_id, :string
    field :revision_number, :integer
    field :kind, :string
    field :bound_digest, :string
    field :reason, :string
    field :note, :string
    field :decided_by, :string
    field :decided_at, :utc_datetime_usec

    belongs_to :goal, Shoestring.Trajectory.Goal
    belongs_to :plan_revision, Shoestring.Cobbler.PlanRevisionRecord

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "Builds the single, complete insert for a terminal decision."
  @spec insert_changeset(
          Ecto.UUID.t(),
          Shoestring.Cobbler.PlanRevisionRecord.t(),
          map(),
          DateTime.t()
        ) ::
          Ecto.Changeset.t()
  def insert_changeset(goal_id, revision, attrs, now) do
    %__MODULE__{}
    |> cast(%{}, [])
    |> put_change(:goal_id, goal_id)
    |> put_change(:plan_revision_id, revision.id)
    |> put_change(:revision_number, revision.revision_number)
    |> put_change(:decision_id, attrs.decision_id)
    |> put_change(:kind, attrs.kind)
    |> put_change(:bound_digest, attrs.digest)
    |> put_change(:reason, Map.get(attrs, :reason))
    |> put_change(:note, Map.get(attrs, :note))
    |> put_change(:decided_by, attrs.decided_by)
    |> put_change(:decided_at, now)
    |> put_change(:inserted_at, now)
    |> put_change(:updated_at, now)
    |> foreign_key_constraint(:goal_id)
    |> foreign_key_constraint(:plan_revision_id)
    |> unique_constraint(:decision_id, name: "cobbler_plan_decisions_goal_id_decision_id_index")
    |> unique_constraint(:plan_revision_id,
      name: "cobbler_plan_decisions_plan_revision_id_index"
    )
    |> check_constraint(:kind, name: "cobbler_plan_decisions_kind_valid")
    |> check_constraint(:reason, name: "cobbler_plan_decisions_reason_required_on_reject")
  end
end
