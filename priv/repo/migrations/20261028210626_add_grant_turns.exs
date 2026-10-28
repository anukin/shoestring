defmodule Shoestring.Repo.Migrations.AddGrantTurns do
  use Ecto.Migration

  # Coordinator turns a grant allows (iteration 15 package D). A grant made
  # before turns existed allows none: its person never approved them, so it
  # must be extended before a conversation can take a turn under it.
  def change do
    alter table(:coordinator_grants) do
      add :max_turns, :integer, null: false, default: 0
      add :turns_used, :integer, null: false, default: 0
    end
  end
end
