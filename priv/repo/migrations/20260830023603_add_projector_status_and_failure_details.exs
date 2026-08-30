defmodule Shoestring.Repo.Migrations.AddProjectorStatusAndFailureDetails do
  use Ecto.Migration

  def change do
    alter table(:projector_positions) do
      add :status, :string, null: false, default: "ok"
      add :error_detail, :text
    end
  end
end
