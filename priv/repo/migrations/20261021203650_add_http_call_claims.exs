defmodule Shoestring.Repo.Migrations.AddHttpCallClaims do
  use Ecto.Migration

  def change do
    create table(:http_call_claims, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, references(:harness_runs, type: :binary_id, on_delete: :restrict), null: false
      add :provider, :string, null: false
      add :status, :string, null: false
    end

    create unique_index(:http_call_claims, [:run_id])
  end
end
