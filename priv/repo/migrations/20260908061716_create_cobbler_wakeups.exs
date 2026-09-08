defmodule Shoestring.Repo.Migrations.CreateCobblerWakeups do
  use Ecto.Migration

  # Milestone 05 work package D+E (T3): durable wake intents for sleeping
  # goals. Rows are effect truth; Oban `wakeup` jobs are durable delivery
  # attempts keyed by the same idempotency key. A wakeup fires at most once:
  # the worker marks it `woken` only after its branch writes commit, and a
  # re-performed `woken` row is a no-op.
  def change do
    create table(:cobbler_wakeups, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false

      add :run_id, references(:harness_runs, type: :binary_id, on_delete: :delete_all)

      add :command_id, :string

      add :wake_at, :utc_datetime_usec, null: false

      add :reason, :string,
        null: false,
        check: %{name: "cobbler_wakeups_reason_present", expr: "length(reason) > 0"}

      add :status, :string,
        null: false,
        default: "scheduled",
        check: %{
          name: "cobbler_wakeups_status_valid",
          expr: "status IN ('scheduled', 'due', 'woken', 'cancelled')"
        }

      add :idempotency_key, :string,
        null: false,
        check: %{
          name: "cobbler_wakeups_idempotency_key_present",
          expr: "length(idempotency_key) > 0"
        }

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:cobbler_wakeups, [:idempotency_key],
             name: :cobbler_wakeups_idempotency_key_index
           )

    create index(:cobbler_wakeups, [:status, :wake_at],
             name: :cobbler_wakeups_status_wake_at_index
           )

    create index(:cobbler_wakeups, [:goal_id], name: :cobbler_wakeups_goal_id_index)
  end
end
