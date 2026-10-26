defmodule Shoestring.Repo.Migrations.AddDispatchReviewer do
  use Ecto.Migration

  # An IMPLEMENT dispatch may name a reviewer from another vendor; iteration
  # 8's cross-review then runs before its task is accepted.
  def change do
    alter table(:coordinator_dispatches) do
      add :reviewer_provider, :string
      add :reviewer_model, :string
    end
  end
end
