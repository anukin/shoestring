defmodule Shoestring.Repo.Migrations.AddPermissionAskKind do
  @moduledoc """
  What a worker's ask is for, so the person is told what allowing it does:
  `command` (run one command outside the sandbox), `file_change` (Codex: a
  file change its sandbox would refuse) or `network` (Claude: reach a host
  not on the agent's list, for the rest of that run).
  """
  use Ecto.Migration

  def change do
    alter table(:permission_asks) do
      add :kind, :string, null: false, default: "command"
    end
  end
end
