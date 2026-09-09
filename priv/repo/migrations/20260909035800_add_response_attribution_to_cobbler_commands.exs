defmodule Shoestring.Repo.Migrations.AddResponseAttributionToCobblerCommands do
  use Ecto.Migration

  # Strict command-response attribution (Milestone 05 follow-up): every NEW
  # response recorded through Commands.respond/4 must carry a non-blank
  # confirmed_by identity (+ the confirmed intent where the caller carries
  # it). Both columns stay NULL-able with no backfill: rows and events
  # written before this migration keep nil attribution and still rebuild.
  def change do
    alter table(:cobbler_commands) do
      add :confirmed_by, :string
      add :confirmed_intent, :string
    end
  end
end
