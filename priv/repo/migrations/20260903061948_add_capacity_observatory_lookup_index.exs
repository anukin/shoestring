defmodule Shoestring.Repo.Migrations.AddCapacityObservatoryLookupIndex do
  use Ecto.Migration

  def change do
    create index(
             :harness_capacity_snapshots,
             [
               :goal_id,
               :source_provider_id,
               :source_invocation_mode,
               :scope,
               :observed_at_v2,
               :projection_sequence,
               :id
             ],
             name: :harness_capacity_snapshots_observatory_lookup_idx
           )
  end
end
