defmodule Shoestring.Repo.Migrations.AddCoordinatorDispatchCalls do
  use Ecto.Migration

  # EXPLORE and REVIEW dispatches (iteration 14) are one model call each, not
  # an Elf run: this row carries the call's progress, its admission, the
  # confirmation that admitted it and its validated result.
  def change do
    create table(:coordinator_dispatch_calls, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :dispatch_id,
          references(:coordinator_dispatches, type: :binary_id, on_delete: :restrict),
          null: false

      add :target_dispatch_id,
          references(:coordinator_dispatches, type: :binary_id, on_delete: :restrict)

      add :state, :string, null: false
      add :admission, :map
      add :defer_until, :utc_datetime_usec
      add :confirmed_by, :string
      add :confirmed_at, :utc_datetime_usec
      add :input_json, :text, null: false
      add :input_digest, :string, null: false
      add :workdir, :text
      add :report_json, :text
      add :report_digest, :string
      add :error_code, :string
      add :output_tokens, :integer
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:coordinator_dispatch_calls, [:dispatch_id])
    create index(:coordinator_dispatch_calls, [:target_dispatch_id])
  end
end
