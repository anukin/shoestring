defmodule Shoestring.Cobbler.PlanProjection do
  @moduledoc "Replaceable projection; canonical plan events retain all immutable content and decisions."
  use Ecto.Schema
  @primary_key {:goal_id, :binary_id, autogenerate: false}
  schema "cobbler_plan_projections" do
    field :state, :map
    field :last_sequence, :integer
  end
end
