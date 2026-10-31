defmodule Shoestring.Repo.Migrations.AddSessionTeam do
  @moduledoc """
  A session's team (iteration 16 package T): the grant records the agents
  the session was started with, their models and limits; each dispatch
  records the agent it was for. Both are nil for what came before.
  """
  use Ecto.Migration

  def change do
    alter table(:coordinator_grants) do
      add :team, :map
    end

    alter table(:coordinator_dispatches) do
      add :agent, :string
    end
  end
end
