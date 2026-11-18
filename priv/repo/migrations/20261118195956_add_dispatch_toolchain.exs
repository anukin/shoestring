defmodule Shoestring.Repo.Migrations.AddDispatchToolchain do
  use Ecto.Migration

  def change do
    alter table(:coordinator_dispatches) do
      add :toolchain, :map
    end
  end
end
