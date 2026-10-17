defmodule Shoestring.Cobbler.Review.Record do
  @moduledoc "One cross-provider review of one plan-task attempt; see `Shoestring.Cobbler.PlanReview`."
  use Ecto.Schema

  @states ~w(pending held running approved changes_requested escalated failed waived rejected)
  def states, do: @states

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "plan_reviews" do
    field :goal_id, :binary_id
    field :execution_id, :binary_id
    field :plan_task_id, :string
    field :attempt, :integer
    field :run_id, :binary_id
    field :round, :integer
    field :base_commit, :string
    field :commit, :string
    field :packet_json, :string
    field :packet_digest, :string
    field :gates, :map
    field :configuration, :map
    field :state, :string, default: "pending"
    field :calls, :integer, default: 0
    field :charged_output_tokens, :integer, default: 0
    field :errors, :map, default: %{"items" => []}
    field :result_json, :string
    field :result_digest, :string
    field :decision_id, :binary_id
    field :duration_ms, :integer, default: 0
    timestamps(type: :utc_datetime_usec)
  end
end
