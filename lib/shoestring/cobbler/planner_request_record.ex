defmodule Shoestring.Cobbler.PlannerRequestRecord do
  @moduledoc "Durable initial planning budget, model-visible projection and attempt outcomes."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "planner_requests" do
    field :goal_id, :binary_id
    field :request_key, :string
    field :input_digest, :string
    field :projection, :map
    field :configuration, :map
    field :state, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :charged_output_tokens, :integer, default: 0
    field :attempt_history, :map, default: %{"items" => []}
    field :errors, :map, default: %{"items" => []}
    field :result_json, :string
    field :result_digest, :string
    timestamps(type: :utc_datetime_usec)
  end
end
