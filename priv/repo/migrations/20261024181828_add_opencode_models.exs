defmodule Shoestring.Repo.Migrations.AddOpencodeModels do
  use Ecto.Migration

  # opencode has no "default" model a run may fall back to, so the list
  # starts empty: no opencode model is selectable until the operator names one.
  def change do
    alter table(:agent_settings) do
      add :opencode_models, :text, null: false, default: ""
    end
  end
end
