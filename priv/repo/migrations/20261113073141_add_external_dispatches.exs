defmodule Shoestring.Repo.Migrations.AddExternalDispatches do
  @moduledoc """
  EXTERNAL dispatches (iteration 20): work a person or a program does
  outside Shoestring, in a run worktree Shoestring made, accepted only by
  Shoestring's checks. One row per EXTERNAL dispatch holds its lifecycle:
  held for the person's confirmation, then awaiting the operator until a
  person completes or abandons it. Nothing here runs or stops a process,
  and the deadline is evidence, never acted on.

  Grants gain `units`: named non-token budgets (`name`, `cap`, `reserve`)
  an EXTERNAL reserves at the start and settles at completion.
  """
  use Ecto.Migration

  def change do
    create table(:coordinator_dispatch_externals, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :dispatch_id, :binary_id, null: false
      # held | awaiting | needs_you | completed | abandoned
      add :state, :string, null: false, default: "held"
      add :confirmed_by, :string
      add :confirmed_at, :utc_datetime_usec
      add :deadline_at, :utc_datetime_usec
      add :run_id, :string
      add :worktree_path, :text
      add :branch, :string
      add :base_commit, :string
      # JSON: name => amount reserved; name => amount reported at completion.
      add :units_reserved, :text, null: false, default: "{}"
      add :units_actual, :text
      add :attempts, :integer, null: false, default: 0
      add :commit, :string
      add :checks, :text
      add :failure, :text
      add :expired, :boolean, null: false, default: false
      add :completed_by, :string
      add :finished_at, :utc_datetime_usec
      add :abandon_reason, :text
      # The person's checkout before and after: HEAD and a status digest.
      add :source_before, :text
      add :source_after, :text
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:coordinator_dispatch_externals, [:dispatch_id])

    alter table(:coordinator_grants) do
      add :units, :text, null: false, default: "[]"
    end
  end
end
