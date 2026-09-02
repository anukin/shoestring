defmodule Shoestring.Repo.Migrations.AddObanDispatch do
  use Ecto.Migration

  def up do
    Oban.Migration.up()

    create table(:harness_dispatches, primary_key: false) do
      add :dispatch_id, :binary_id, primary_key: true
      add :goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false
      add :task_id, references(:tasks, type: :binary_id, on_delete: :nilify_all)

      add :run_id, references(:harness_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :request_version, :integer,
        null: false,
        check: %{name: "harness_dispatches_request_version_positive", expr: "request_version > 0"}

      add :status, :string,
        null: false,
        default: "requested",
        check: %{
          name: "harness_dispatches_status_valid",
          expr:
            "status IN ('requested', 'effect_started', 'effect_failed', 'effect_unknown', 'effect_completed', 'cancelled')"
        }

      add :job_id, references(:oban_jobs, type: :bigint, on_delete: :nilify_all)
      add :outcome_code, :string
      add :outcome_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:harness_dispatches, [:job_id])
    create index(:harness_dispatches, [:goal_id, :status])
    create index(:harness_dispatches, [:run_id, :status])
  end

  def down do
    drop table(:harness_dispatches)
    Oban.Migration.down()
  end
end
