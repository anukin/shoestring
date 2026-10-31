defmodule Shoestring.Repo.Migrations.AddDispatchCallProgress do
  use Ecto.Migration

  # What an EXPLORE call's explorer did while it ran (iteration 16): its last
  # steps and how many there were, shown with the dispatch's log.
  def change do
    alter table(:coordinator_dispatch_calls) do
      add :progress, :map
    end
  end
end
