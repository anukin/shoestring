defmodule Shoestring.Repo.Migrations.AddHarnessModels do
  use Ecto.Migration

  # What each harness last reported it offers, plus models the operator named
  # by hand. Whether a model may be used stays in agent_settings' lists.
  def change do
    create table(:harness_models, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :provider, :string, null: false
      add :model, :string, null: false
      add :display_name, :string
      add :efforts, :text, null: false, default: "[]"
      add :default_effort, :string
      add :harness_default, :boolean, null: false, default: false
      add :resolves_to, :string
      add :source, :string, null: false
      add :available, :boolean, null: false, default: true
      add :first_seen_at, :utc_datetime_usec, null: false
      add :fetched_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:harness_models, [:provider, :model])
  end
end
