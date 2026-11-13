defmodule Shoestring.Decisions.Decision do
  @moduledoc """
  One decision point of one plan task attempt: the question, the candidates
  (each stored as an artifact) and, once a person answered, the answer.

  `state` is `pending`, `answered`, `rejected` (a person chose "none of
  these") or `withdrawn` (the goal was cancelled first). Rows are written
  only by `Shoestring.Decisions`; the trajectory events
  `cobbler.plan.decision.*` are the canonical record the executor reads.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "plan_decisions" do
    field :goal_id, :binary_id
    field :execution_id, :binary_id
    field :plan_task_id, :string
    field :attempt, :integer
    field :run_id, :binary_id
    field :key, :string
    field :question, :string
    field :note, :string
    # Each: "key", "label", "media_type", "file", "artifact_id", and
    # "source" (a worktree path to the full candidate) when the task gave one.
    field :options, {:array, :map}
    field :allow_reject, :boolean
    field :state, :string, default: "pending"
    field :answer_key, :string
    field :answer_note, :string
    field :decided_by, :string
    field :decided_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
