defmodule Shoestring.Repo.Migrations.AddDispatchSetup do
  use Ecto.Migration

  def change do
    alter table(:coordinator_dispatches) do
      add :setup, :map
    end
  end
end
