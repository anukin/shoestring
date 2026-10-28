defmodule Shoestring.Repo.Migrations.CreateCoordinatorConversations do
  use Ecto.Migration

  # A coordinator session's conversation (iteration 15 package C). Its id is
  # the goal whose trajectory holds the conversation's events; this row is how
  # a session finds it, and the coordinator binding its turns run with.
  def change do
    create table(:coordinator_conversations, primary_key: false) do
      add :id, references(:goals, type: :binary_id, on_delete: :restrict), primary_key: true
      add :session_id, :string, null: false
      add :provider, :string, null: false
      add :model, :string, null: false
      add :effort, :string
      add :repository_root, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:coordinator_conversations, [:session_id])
  end
end
