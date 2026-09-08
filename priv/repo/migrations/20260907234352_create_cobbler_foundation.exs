defmodule Shoestring.Repo.Migrations.CreateCobblerFoundation do
  use Ecto.Migration

  def change do
    create table(:cobbler_commands, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :command_id, :string, null: false
      add :goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false
      add :intent_id, :binary_id
      add :command_type, :string, null: false
      add :payload, :map, null: false
      add :payload_hash, :string, null: false
      add :status, :string, null: false
      add :result, :map, null: false
      add :trajectory_event_id, :binary_id

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:cobbler_commands, [:goal_id, :command_id],
             name: :cobbler_commands_goal_id_command_id_index
           )

    create index(:cobbler_commands, [:goal_id, :intent_id])

    create table(:cobbler_intents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false
      add :task_id, references(:tasks, type: :binary_id, on_delete: :nilify_all)
      add :title, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :requested_capability, :string, null: false
      add :provider_id, :string, null: false
      add :account_id, :string, null: false
      add :scope, :string, null: false
      add :admission_decision_id, :binary_id, null: false
      add :proposed_bounds, :map, null: false
      add :override, :map
      add :recovery_data, :map
      add :terminal_reason, :string
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:cobbler_intents, [:goal_id, :status])
    create index(:cobbler_intents, [:provider_id, :scope])

    create table(:cobbler_claims, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :claim_slot, :string, null: false, default: "global_active"
      add :active_slot, :string
      add :goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false

      add :intent_id, references(:cobbler_intents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :command_id, :string, null: false
      add :provider_id, :string, null: false
      add :account_id, :string, null: false
      add :scope, :string, null: false
      add :status, :string, null: false, default: "active"
      add :claimed_at, :utc_datetime_usec, null: false
      add :released_at, :utc_datetime_usec
      add :release_reason, :string
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:cobbler_claims, [:active_slot], name: :cobbler_claims_active_slot_index)

    create unique_index(:cobbler_claims, [:claim_slot],
             where: "status = 'active'",
             name: :cobbler_claims_singleton_active_index
           )

    create index(:cobbler_claims, [:goal_id, :intent_id])
    create index(:cobbler_claims, [:status])
  end
end
