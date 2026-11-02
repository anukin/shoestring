defmodule Shoestring.Repo.Migrations.AddSessionDays do
  @moduledoc """
  How many days back the Sessions page lists coordinator sessions. Older
  sessions are kept, only hidden.
  """
  use Ecto.Migration

  def change do
    alter table(:agent_settings) do
      add :session_days, :integer, null: false, default: 7
    end
  end
end
