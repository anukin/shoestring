defmodule Shoestring.Repo.Migrations.AddPlanChildInbox do
  use Ecto.Migration

  def change do
    create table(:cobbler_plan_child_inbox, primary_key: false) do
      add :event_id, references(:trajectory_events, type: :binary_id, on_delete: :restrict),
        primary_key: true

      add :goal_id, references(:goals, type: :binary_id, on_delete: :restrict), null: false
      add :execution_id, :binary_id, null: false
      add :plan_task_id, :string, null: false
      add :revision_number, :integer, null: false
      add :plan_digest, :string, null: false
      add :attempt, :integer, null: false

      add :root_run_id, references(:harness_runs, type: :binary_id, on_delete: :restrict),
        null: false

      add :run_id, references(:harness_runs, type: :binary_id, on_delete: :restrict), null: false
      add :source_sequence, :integer, null: false
      add :source_type, :string, null: false
      add :message_kind, :string, null: false

      add :status, :string,
        null: false,
        default: "pending",
        check: %{name: "plan_child_inbox_status_valid", expr: "status IN ('pending', 'observed')"}

      # Oban jobs are disposable delivery. Keep the old ID after pruning; repair
      # recreates delivery from the canonical source without deleting evidence.
      add :job_id, :integer

      add :observation_event_id,
          references(:trajectory_events, type: :binary_id, on_delete: :restrict)

      add :last_reason, :string
      timestamps(type: :utc_datetime_usec)
    end

    create index(:cobbler_plan_child_inbox, [:goal_id, :execution_id, :source_sequence])
    create index(:cobbler_plan_child_inbox, [:status])
  end
end
