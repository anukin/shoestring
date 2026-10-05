defmodule Shoestring.Repo.Migrations.AddPlannerRequests do
  use Ecto.Migration

  def change do
    create table(:planner_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :goal_id, references(:goals, type: :binary_id, on_delete: :restrict), null: false
      add :request_key, :string, null: false
      add :input_digest, :string, null: false
      add :projection, :map, null: false
      add :configuration, :map, null: false
      add :state, :string, null: false, default: "pending"

      add :attempts, :integer,
        null: false,
        default: 0,
        check: %{name: "planner_attempt_bounds", expr: "attempts >= 0 AND attempts <= 2"}

      add :charged_output_tokens, :integer,
        null: false,
        default: 0,
        check: %{name: "planner_token_bounds", expr: "charged_output_tokens >= 0"}

      add :attempt_history, :map, null: false, default: %{"items" => []}
      add :errors, :map, null: false, default: %{"items" => []}
      add :result_json, :text
      add :result_digest, :string
      timestamps(type: :utc_datetime_usec)
    end

    # New request keys cannot reset the initial planning budget. Replanning
    # after execution belongs to the amendment package and its own contract.
    create unique_index(:planner_requests, [:goal_id])
  end
end
