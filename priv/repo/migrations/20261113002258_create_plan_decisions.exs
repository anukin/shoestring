defmodule Shoestring.Repo.Migrations.CreatePlanDecisions do
  @moduledoc """
  A decision point (iteration 19): a plan task wrote N candidates and the
  plan waits, before its dependents, for a person to choose one. Durable and
  process-free: no worker waits on it, nothing decides it by a timer, and it
  survives a restart. The first human answer wins (a conditional update on
  `state`). One row per task attempt; the candidates are artifacts.
  """
  use Ecto.Migration

  def change do
    create table(:plan_decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :goal_id, :binary_id, null: false
      add :execution_id, :binary_id, null: false
      add :plan_task_id, :string, null: false
      add :attempt, :integer, null: false
      add :run_id, :binary_id, null: false
      # The decision id the plan declared (a slug, also its directory name).
      add :key, :string, null: false
      add :question, :text, null: false
      add :note, :text
      # JSON list: key, label, media_type, file, artifact_id, optional source.
      add :options, :text, null: false
      add :allow_reject, :boolean, null: false
      # pending | answered | rejected | withdrawn
      add :state, :string, null: false, default: "pending"
      add :answer_key, :string
      add :answer_note, :text
      add :decided_by, :string
      add :decided_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:plan_decisions, [:goal_id, :execution_id, :plan_task_id, :attempt])
    create index(:plan_decisions, [:goal_id, :state])
    create index(:plan_decisions, [:state])
  end
end
