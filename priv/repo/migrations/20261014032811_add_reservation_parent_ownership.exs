defmodule Shoestring.Repo.Migrations.AddReservationParentOwnership do
  use Ecto.Migration

  def change do
    alter table(:cobbler_capacity_reservations) do
      add :parent_id,
          references(:cobbler_capacity_reservations, type: :binary_id, on_delete: :restrict)
    end

    # Preserve every owner. The original uniqueness rule applies to roots;
    # one successor per parent serializes continuation ownership separately.
    drop unique_index(:cobbler_capacity_reservations, [
           :goal_id,
           :execution_id,
           :plan_task_id,
           :attempt
         ])

    create unique_index(
             :cobbler_capacity_reservations,
             [:goal_id, :execution_id, :plan_task_id, :attempt],
             where: "parent_id IS NULL"
           )

    create unique_index(:cobbler_capacity_reservations, [:parent_id])
  end
end
