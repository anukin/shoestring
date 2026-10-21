defmodule Shoestring.Repo.Migrations.AddApiSpendReservations do
  use Ecto.Migration

  def change do
    create table(:api_spend_reservations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :goal_id, references(:goals, type: :binary_id, on_delete: :restrict), null: false
      add :run_id, references(:harness_runs, type: :binary_id, on_delete: :restrict), null: false
      add :version, :integer, null: false
      add :pricing, :map, null: false
      add :monthly_cap_microusd, :bigint, null: false

      add :maximum_microusd, :bigint,
        null: false,
        check: %{
          name: "api_spend_amounts_valid",
          expr:
            "version = 1 AND monthly_cap_microusd > 0 AND maximum_microusd > 0 AND maximum_microusd <= monthly_cap_microusd"
        }

      add :reserved_at, :utc_datetime_usec, null: false
      add :reserved_month, :string, null: false

      add :status, :string,
        null: false,
        check: %{
          name: "api_spend_status_valid",
          expr: "status IN ('reserved', 'unresolved', 'reconciled')"
        }

      add :input_tokens, :bigint
      add :output_tokens, :bigint

      add :reconciled_microusd, :bigint,
        check: %{
          name: "api_spend_settlement_valid",
          expr:
            "(status = 'reconciled' AND input_tokens IS NOT NULL AND output_tokens IS NOT NULL AND reconciled_microusd IS NOT NULL AND input_tokens >= 0 AND output_tokens >= 0 AND reconciled_microusd >= 0 AND reconciled_microusd <= maximum_microusd AND reconciled_at IS NOT NULL AND reconciled_month IS NOT NULL) OR (status != 'reconciled' AND input_tokens IS NULL AND output_tokens IS NULL AND reconciled_microusd IS NULL AND reconciled_at IS NULL AND reconciled_month IS NULL)"
        }

      add :reconciled_at, :utc_datetime_usec
      add :reconciled_month, :string
    end

    create index(:api_spend_reservations, [:status, :reserved_month, :reconciled_month])
  end
end
