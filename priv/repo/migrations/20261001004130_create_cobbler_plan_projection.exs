defmodule Shoestring.Repo.Migrations.CreateCobblerPlanProjection do
  use Ecto.Migration

  def change do
    create table(:cobbler_plan_projections, primary_key: false) do
      add :goal_id, references(:goals, type: :binary_id, on_delete: :restrict), primary_key: true
      add :state, :map, null: false
      add :last_sequence, :integer, null: false, default: 0
    end
  end
end
