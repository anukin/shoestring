defmodule Shoestring.Repo.Migrations.AddHarnessRunRequestExtensions do
  use Ecto.Migration

  def change do
    alter table(:harness_runs) do
      add :extensions, :map, null: false, default: %{}
    end
  end
end
