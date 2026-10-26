defmodule Shoestring.Repo.Migrations.AddCoordinatorGrantsAndDispatches do
  use Ecto.Migration

  # A grant is a person's allowance for one coordinator session; its events
  # are the append-only record of who granted, extended or revoked what. A
  # dispatch is one task a coordinator handed to Shoestring under a grant.
  def change do
    create table(:coordinator_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, :string, null: false
      add :granted_by, :string, null: false
      add :repository_root, :text, null: false
      add :models, :text, null: false
      add :purposes, :text, null: false
      add :max_dispatches, :integer, null: false
      add :max_parallel, :integer, null: false
      add :max_total_seconds, :integer, null: false
      add :max_dispatch_seconds, :integer, null: false
      add :unread_usage, :integer, null: false, default: 0
      add :unread_usage_used, :integer, null: false, default: 0
      add :limits_revision, :integer, null: false, default: 1
      add :revoked_at, :utc_datetime_usec
      add :revoked_by, :string
      timestamps(type: :utc_datetime_usec)
    end

    create index(:coordinator_grants, [:session_id])

    create table(:coordinator_grant_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :grant_id, references(:coordinator_grants, type: :binary_id, on_delete: :restrict),
        null: false

      add :kind, :string, null: false
      add :actor, :string, null: false
      add :payload, :map, null: false
      add :occurred_at, :utc_datetime_usec, null: false
    end

    create index(:coordinator_grant_events, [:grant_id])

    create table(:coordinator_dispatches, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :grant_id, references(:coordinator_grants, type: :binary_id, on_delete: :restrict),
        null: false

      add :session_id, :string, null: false
      add :request_id, :string, null: false
      add :purpose, :string, null: false
      add :provider, :string, null: false
      add :model, :string, null: false
      add :effort, :string
      add :title, :string, null: false
      add :brief, :text, null: false
      add :brief_digest, :string, null: false
      add :repository_root, :text, null: false
      add :base_revision, :string, null: false
      add :max_attempts, :integer, null: false
      add :max_duration_seconds, :integer, null: false
      add :batch_label, :string
      add :batch_size, :integer
      add :goal_id, :binary_id
      add :plan, :map, null: false
      add :plan_digest, :string, null: false
      add :execution_id, :string
      add :state, :string, null: false
      add :error, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:coordinator_dispatches, [:session_id, :request_id])
    create unique_index(:coordinator_dispatches, [:goal_id])
    create index(:coordinator_dispatches, [:grant_id])
  end
end
