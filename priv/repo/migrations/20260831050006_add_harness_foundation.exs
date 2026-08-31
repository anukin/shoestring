defmodule Shoestring.Repo.Migrations.AddHarnessFoundation do
  use Ecto.Migration

  def change do
    create table(:harness_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false
      add :task_id, references(:tasks, type: :binary_id, on_delete: :nilify_all)
      add :dispatch_id, :binary_id, null: false
      add :provider_id, :string, null: false
      add :workspace_ref, :string, null: false

      add :request_version, :integer,
        null: false,
        check: %{name: "harness_runs_request_version_positive", expr: "request_version > 0"}

      add :prompt, :text, null: false
      add :continuation, :map
      add :policy, :map, null: false
      add :requested_capabilities, :map, null: false

      add :status, :string,
        null: false,
        default: "requested",
        check: %{
          name: "harness_runs_status_valid",
          expr:
            "status IN ('requested', 'starting', 'running', 'pausing', 'suspended', 'completed', 'failed', 'cancelling', 'cancelled')"
        }

      add :provider_session_id, :string

      add :projection_sequence, :integer,
        null: false,
        default: 0,
        check: %{
          name: "harness_runs_projection_sequence_nonnegative",
          expr: "projection_sequence >= 0"
        }

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:harness_runs, [:dispatch_id])
    create index(:harness_runs, [:goal_id, :status])
    create index(:harness_runs, [:goal_id, :task_id])
    create index(:trajectory_events, [:goal_id, :run_id, :sequence])

    create table(:harness_capacity_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false
      add :run_id, references(:harness_runs, type: :binary_id, on_delete: :nilify_all)

      add :contract_version, :integer,
        null: false,
        check: %{
          name: "harness_capacity_snapshots_version_positive",
          expr: "contract_version > 0"
        }

      add :capacity_state, :string,
        null: false,
        check: %{
          name: "harness_capacity_snapshots_state_valid",
          expr: "capacity_state IN ('known', 'unknown')"
        }

      add :observed_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec
      add :source_adapter_id, :string, null: false
      add :source_method, :string, null: false
      add :scope, :string, null: false
      add :confidence, :string, null: false
      add :support_tier, :string, null: false
      add :compatibility_state, :string, null: false
      add :extensions, :map, null: false
      add :projection_sequence, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:harness_capacity_snapshots, [:goal_id, :observed_at])
    create index(:harness_capacity_snapshots, [:run_id, :observed_at])
    create index(:harness_capacity_snapshots, [:compatibility_state, :support_tier])

    create table(:harness_capacity_windows, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :snapshot_id,
          references(:harness_capacity_snapshots, type: :binary_id, on_delete: :delete_all),
          null: false

      add :kind, :string, null: false

      add :state, :string,
        null: false,
        check: %{
          name: "harness_capacity_windows_state_valid",
          expr: "state IN ('known', 'unknown')"
        }

      add :used_percent, :float,
        check: %{
          name: "harness_capacity_windows_used_percent_range",
          expr: "used_percent IS NULL OR (used_percent >= 0 AND used_percent <= 100)"
        }

      add :reset_at, :utc_datetime_usec
      add :unknown_reason, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:harness_capacity_windows, [:snapshot_id, :kind])
    create index(:harness_capacity_windows, [:reset_at])

    create table(:harness_execution_leases, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false

      add :run_id, references(:harness_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :admitted_snapshot_id,
          references(:harness_capacity_snapshots, type: :binary_id, on_delete: :restrict),
          null: false

      add :contract_version, :integer,
        null: false,
        check: %{name: "harness_execution_leases_version_positive", expr: "contract_version > 0"}

      add :response_reserve, :integer, null: false
      add :tool_reserve, :integer, null: false
      add :response_budget, :integer, null: false
      add :tool_budget, :integer, null: false
      add :deadline, :utc_datetime_usec, null: false
      add :checkpoint_cadence, :integer, null: false

      add :renewal_state, :string,
        null: false,
        check: %{
          name: "harness_execution_leases_renewal_state_valid",
          expr: "renewal_state IN ('none', 'eligible', 'due', 'renewed', 'expired', 'revoked')"
        }

      add :status, :string,
        null: false,
        default: "proposed",
        check: %{
          name: "harness_execution_leases_status_valid",
          expr:
            "status IN ('proposed', 'granted', 'active', 'renewal_due', 'renewed', 'expired', 'revoked', 'checkpoint_required')"
        }

      add :extensions, :map, null: false
      add :projection_sequence, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:harness_execution_leases, [:goal_id, :status])
    create index(:harness_execution_leases, [:run_id, :deadline])

    create table(:harness_checkpoints, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false

      add :run_id, references(:harness_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :contract_version, :integer,
        null: false,
        check: %{name: "harness_checkpoints_version_positive", expr: "contract_version > 0"}

      add :acceptance_contract, :map, null: false
      add :repository_state, :map, null: false
      add :evidence, :map, null: false
      add :decisions, :map, null: false
      add :unresolved_issues, :map, null: false
      add :next_action, :text, null: false
      add :provider_session_id, :string
      add :stop_reason, :string, null: false
      add :extensions, :map, null: false
      add :projection_sequence, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:harness_checkpoints, [:goal_id, :inserted_at])
    create index(:harness_checkpoints, [:run_id, :inserted_at])

    create table(:harness_checkpoint_artifact_references, primary_key: false) do
      add :checkpoint_id,
          references(:harness_checkpoints, type: :binary_id, on_delete: :delete_all),
          null: false

      add :artifact_id, references(:artifacts, type: :binary_id, on_delete: :restrict),
        null: false
    end

    create unique_index(:harness_checkpoint_artifact_references, [:checkpoint_id, :artifact_id])
    create index(:harness_checkpoint_artifact_references, [:artifact_id])
  end
end
