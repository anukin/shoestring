defmodule Shoestring.Repo.Migrations.CreatePermissionAsks do
  @moduledoc """
  A worker's request, mid-run, for more than its sandbox allows (iteration 16
  permissions): what it asked and why, and the person's decision. Only the
  person decides; nothing is ever decided by a timer. An ask whose session
  ended before a decision is expired. Agents gain `may_ask`: whether their
  worker may ask at all (on by default; off, a request is refused at once
  as before).
  """
  use Ecto.Migration

  def change do
    create table(:permission_asks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :goal_id, :binary_id, null: false
      add :run_id, :string, null: false
      add :dispatch_id, :binary_id
      add :session_id, :string
      add :agent, :string
      add :provider, :string, null: false
      add :command, :text, null: false
      add :reason, :text
      add :cwd, :text
      add :state, :string, null: false, default: "pending"
      add :note, :text
      add :decided_by, :string
      add :decided_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:permission_asks, [:session_id, :state])
    create index(:permission_asks, [:run_id])

    alter table(:agents) do
      add :may_ask, :boolean, null: false, default: true
    end
  end
end
