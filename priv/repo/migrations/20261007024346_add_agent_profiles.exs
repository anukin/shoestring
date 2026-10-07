defmodule Shoestring.Repo.Migrations.AddAgentProfiles do
  use Ecto.Migration

  def up do
    create table(:agent_definitions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :purpose, :text, null: false
      add :instructions, :text, null: false
      add :roles, :map, null: false
      add :revision, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_definitions, [:slug])

    create table(:agent_revisions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :definition_id, references(:agent_definitions, type: :binary_id, on_delete: :restrict),
        null: false

      add :number, :integer, null: false
      add :configuration, :map, null: false
      add :digest, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:agent_revisions, [:definition_id, :number])

    for operation <- ["UPDATE", "DELETE"] do
      execute(
        "CREATE TRIGGER agent_revisions_no_#{String.downcase(operation)} BEFORE #{operation} ON agent_revisions BEGIN SELECT RAISE(ABORT, 'agent revisions are immutable'); END"
      )
    end

    create table(:agent_settings) do
      add :default_agent_id,
          references(:agent_definitions, type: :binary_id, on_delete: :restrict)

      add :refresh_seconds, :integer, null: false, default: 60
      add :claude_models, :text, null: false, default: "default"
      add :codex_models, :text, null: false, default: "default"
      add :lock_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    execute(
      "INSERT INTO agent_settings (id, inserted_at, updated_at) VALUES (1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
    )
  end

  def down do
    drop table(:agent_settings)
    execute("DROP TRIGGER agent_revisions_no_update")
    execute("DROP TRIGGER agent_revisions_no_delete")
    drop table(:agent_revisions)
    drop table(:agent_definitions)
  end
end
