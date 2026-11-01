defmodule Shoestring.Repo.Migrations.AddAgentPermissions do
  @moduledoc """
  What a person lets an implementer agent do beyond its sandbox's defaults
  (iteration 16 permissions): extra folders it may read or write and the
  network hosts it may reach, each a JSON list, empty by default (nothing
  beyond the sandbox). A dispatch keeps a copy of its agent's permissions
  from when its session started, as it keeps the agent's other settings.
  """
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :read_paths, :text, null: false, default: "[]"
      add :write_paths, :text, null: false, default: "[]"
      add :network_hosts, :text, null: false, default: "[]"
    end

    alter table(:coordinator_dispatches) do
      add :permissions, :text
    end
  end
end
