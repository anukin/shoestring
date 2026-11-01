defmodule Shoestring.Repo.Migrations.AddAgentCommandRules do
  @moduledoc """
  "Allow for this agent" (iteration 16 permissions): the exact commands an
  implementer's workers may run outside their sandbox without asking again,
  a JSON list, empty by default. Each ask records the command a rule would
  match (`rule_key`), or nothing when no rule may cover it (a file change, a
  compound shell command).
  """
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :allowed_commands, :text, null: false, default: "[]"
    end

    alter table(:permission_asks) do
      add :rule_key, :text
    end
  end
end
