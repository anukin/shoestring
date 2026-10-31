defmodule Shoestring.Repo.Migrations.AddDispatchAfter do
  @moduledoc """
  Dependent dispatches (iteration 16 C1): an IMPLEMENT may follow another
  IMPLEMENT of its session. It waits, recorded with its grant room reserved,
  until that one completes, then starts from its verified commit. Nil for
  every dispatch that follows none.
  """
  use Ecto.Migration

  def change do
    alter table(:coordinator_dispatches) do
      add :after_dispatch_id, :binary_id
    end

    create index(:coordinator_dispatches, [:after_dispatch_id])
  end
end
