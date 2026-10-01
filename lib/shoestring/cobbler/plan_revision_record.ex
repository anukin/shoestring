defmodule Shoestring.Cobbler.PlanRevisionRecord do
  @moduledoc """
  Durable row for one immutable plan revision.

  A revision is written once. `content`, `digest`, `revision_number`,
  `parent_revision_number`, and the authorship fields are set at insert and
  never updated; editing a plan creates the NEXT revision rather than
  rewriting this one, which is what makes an approval that bound this
  digest keep meaning the same thing forever.

  The only field that moves after insert is `status`:

      proposed -> approved    (a human decision bound to this exact digest)
      proposed -> rejected    (a human decision with a recorded reason)
      approved -> superseded  (a later revision of the same goal was approved)

  `superseded` is terminal and inert. A superseded revision authorizes
  nothing, and marking it superseded cancels nothing: supersession is a
  statement about future authority, never an interrupt against work already
  running under the revision that held it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Shoestring.Cobbler.PlanContract

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(proposed approved rejected superseded)

  schema "cobbler_plan_revisions" do
    field :proposal_id, :string
    field :revision_number, :integer
    field :parent_revision_number, :integer
    field :plan_version, :integer
    field :digest, :string
    field :content, :map
    field :status, :string
    field :authored_by, :string
    field :author_kind, :string, default: "human"
    field :task_count, :integer

    belongs_to :goal, Shoestring.Trajectory.Goal

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Builds the single, complete insert for a newly proposed revision."
  @spec insert_changeset(
          Ecto.UUID.t(),
          String.t(),
          PlanContract.t(),
          pos_integer(),
          pos_integer() | nil,
          String.t(),
          DateTime.t()
        ) :: Ecto.Changeset.t()
  def insert_changeset(
        goal_id,
        proposal_id,
        %PlanContract{} = contract,
        revision_number,
        parent_revision_number,
        authored_by,
        now
      ) do
    %__MODULE__{}
    |> cast(%{}, [])
    |> put_change(:goal_id, goal_id)
    |> put_change(:proposal_id, proposal_id)
    |> put_change(:revision_number, revision_number)
    |> put_change(:parent_revision_number, parent_revision_number)
    |> put_change(:plan_version, contract.version)
    |> put_change(:digest, contract.digest)
    |> put_change(:content, contract.content)
    |> put_change(:status, "proposed")
    |> put_change(:authored_by, authored_by)
    |> put_change(:author_kind, "human")
    |> put_change(:task_count, length(contract.content["tasks"]))
    |> put_change(:inserted_at, now)
    |> put_change(:updated_at, now)
    |> foreign_key_constraint(:goal_id)
    |> unique_constraint(:revision_number,
      name: "cobbler_plan_revisions_goal_id_revision_number_index"
    )
    |> unique_constraint(:proposal_id,
      name: "cobbler_plan_revisions_goal_id_proposal_id_index"
    )
    |> check_constraint(:status, name: "cobbler_plan_revisions_status_valid")
    |> check_constraint(:author_kind, name: "cobbler_plan_revisions_author_kind_human")
    |> check_constraint(:parent_revision_number,
      name: "cobbler_plan_revisions_parent_before_child"
    )
  end

  @doc """
  Moves a revision to a new status, touching nothing else.

  The content, digest, and lineage are deliberately not castable here: a
  status transition can never rewrite what was approved.
  """
  @spec status_changeset(t(), String.t(), DateTime.t()) :: Ecto.Changeset.t()
  def status_changeset(%__MODULE__{} = record, status, now) when status in @statuses do
    record
    |> cast(%{}, [])
    |> put_change(:status, status)
    |> put_change(:updated_at, now)
    |> unique_constraint(:status, name: "cobbler_plan_revisions_goal_id_index")
    |> check_constraint(:status, name: "cobbler_plan_revisions_status_valid")
  end
end
