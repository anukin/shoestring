defmodule Shoestring.Repo.Migrations.AddPlanReviews do
  use Ecto.Migration

  def change do
    # One cross-provider review per plan-task attempt. The packet, the gate
    # evidence it reviewed and the bound reviewer configuration are immutable
    # once recorded; calls and charged output tokens only grow.
    create table(:plan_reviews, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :goal_id, references(:goals, type: :binary_id, on_delete: :restrict), null: false
      add :execution_id, :binary_id, null: false
      add :plan_task_id, :string, null: false
      add :attempt, :integer, null: false
      add :run_id, :binary_id, null: false
      add :round, :integer, null: false
      add :base_commit, :string, null: false
      add :commit, :string, null: false
      add :packet_json, :text, null: false
      add :packet_digest, :string, null: false
      add :gates, :map, null: false
      add :configuration, :map, null: false
      add :state, :string, null: false, default: "pending"

      add :calls, :integer,
        null: false,
        default: 0,
        check: %{name: "plan_review_call_bounds", expr: "calls >= 0 AND calls <= 2"}

      add :charged_output_tokens, :integer,
        null: false,
        default: 0,
        check: %{name: "plan_review_token_bounds", expr: "charged_output_tokens >= 0"}

      add :errors, :map, null: false, default: %{"items" => []}
      add :result_json, :text
      add :result_digest, :string
      add :decision_id, :binary_id
      add :duration_ms, :integer, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:plan_reviews, [:execution_id, :plan_task_id, :attempt])
    create index(:plan_reviews, [:goal_id])
  end
end
