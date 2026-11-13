defmodule Shoestring.Dispatches.External do
  @moduledoc """
  The lifecycle of one EXTERNAL dispatch (`Shoestring.Dispatches.Externals`):
  work done outside Shoestring, in the run worktree Shoestring made for it,
  accepted only by Shoestring's checks.

  States: `held` (waits for the person's confirmation), `awaiting` (the
  worktree exists; the operator works in it until a person completes or
  abandons it), `needs_you` (a completion's checks failed or the worktree
  was not clean; it may be completed again), `completed` (the checks passed
  at `commit`) and `abandoned`. `deadline_at` is evidence only: past it the
  dispatch is reported `expired` and stays answerable.
  """
  use Ecto.Schema

  @states ~w(held awaiting needs_you completed abandoned)
  def states, do: @states

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "coordinator_dispatch_externals" do
    field :dispatch_id, :binary_id
    field :state, :string, default: "held"
    field :confirmed_by, :string
    field :confirmed_at, :utc_datetime_usec
    field :deadline_at, :utc_datetime_usec
    field :run_id, :string
    field :worktree_path, :string
    field :branch, :string
    field :base_commit, :string
    field :units_reserved, :map, default: %{}
    field :units_actual, :map
    field :attempts, :integer, default: 0
    field :commit, :string
    field :checks, {:array, :map}
    field :failure, :string
    field :expired, :boolean, default: false
    field :completed_by, :string
    field :finished_at, :utc_datetime_usec
    field :abandon_reason, :string
    field :source_before, :map
    field :source_after, :map
    timestamps(type: :utc_datetime_usec)
  end
end
