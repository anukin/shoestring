defmodule Shoestring.Repo.Migrations.CreateTrajectoryFoundation do
  use Ecto.Migration

  def change do
    create table(:goals, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :owner_id, :binary_id, null: false
      add :title, :string, null: false
      add :description, :string
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:goals, [:owner_id])
    create index(:goals, [:status])

    create table(:tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false
      add :title, :string, null: false
      add :description, :string
      add :status, :string, null: false, default: "pending"

      add :position, :integer,
        null: false,
        default: 0,
        check: %{name: "tasks_position_nonnegative", expr: "position >= 0"}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:tasks, [:goal_id, :position])
    create index(:tasks, [:goal_id, :status])

    create table(:trajectory_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false
      add :task_id, references(:tasks, type: :binary_id, on_delete: :nilify_all)
      add :run_id, :binary_id

      add :sequence, :integer,
        null: false,
        check: %{name: "trajectory_events_sequence_positive", expr: "sequence > 0"}

      add :parent_event_id,
          references(:trajectory_events, type: :binary_id, on_delete: :nilify_all)

      add :type, :string,
        null: false,
        check: %{name: "trajectory_events_type_present", expr: "length(type) > 0"}

      add :actor, :string,
        null: false,
        check: %{name: "trajectory_events_actor_present", expr: "length(actor) > 0"}

      add :occurred_at, :utc_datetime_usec, null: false

      add :schema_version, :integer,
        null: false,
        check: %{name: "trajectory_events_schema_version_positive", expr: "schema_version > 0"}

      add :payload, :map, null: false

      add :idempotency_key, :string,
        check: %{
          name: "trajectory_events_idempotency_key_present",
          expr: "idempotency_key IS NULL OR length(idempotency_key) > 0"
        }
    end

    create unique_index(:trajectory_events, [:goal_id, :sequence])

    create unique_index(:trajectory_events, [:goal_id, :idempotency_key],
             where: "idempotency_key IS NOT NULL"
           )

    create index(:trajectory_events, [:task_id, :sequence])
    create index(:trajectory_events, [:parent_event_id])

    create table(:artifacts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false
      add :task_id, references(:tasks, type: :binary_id, on_delete: :nilify_all)
      add :sha256, :string, null: false

      add :byte_size, :integer,
        null: false,
        check: %{name: "artifacts_byte_size_nonnegative", expr: "byte_size >= 0"}

      add :media_type, :string, null: false
      add :location, :string, null: false
      add :redacted, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:artifacts, [:goal_id])
    create index(:artifacts, [:task_id])
    create index(:artifacts, [:sha256])

    create table(:projector_positions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false
      add :projector, :string, null: false

      add :version, :integer,
        null: false,
        check: %{name: "projector_positions_version_positive", expr: "version > 0"}

      add :last_sequence, :integer,
        null: false,
        default: 0,
        check: %{name: "projector_positions_sequence_nonnegative", expr: "last_sequence >= 0"}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:projector_positions, [:goal_id, :projector])
    create index(:projector_positions, [:projector, :version])
  end
end
