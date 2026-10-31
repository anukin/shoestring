defmodule Shoestring.Repo.Migrations.AddConversationHandoff do
  use Ecto.Migration

  # A handoff (iteration 16 package A) continues a session in a fresh
  # conversation: the session keeps a chain of them, and only the newest,
  # not handed off, is its current one.
  def change do
    alter table(:coordinator_conversations) do
      add :predecessor_id, :binary_id
      add :handed_off_at, :utc_datetime_usec
    end

    drop unique_index(:coordinator_conversations, [:session_id])

    create unique_index(:coordinator_conversations, [:session_id],
             where: "handed_off_at IS NULL",
             name: :coordinator_conversations_current_session_index
           )

    create unique_index(:coordinator_conversations, [:predecessor_id])
  end
end
