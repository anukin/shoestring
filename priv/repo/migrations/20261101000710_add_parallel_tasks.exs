defmodule Shoestring.Repo.Migrations.AddParallelTasks do
  @moduledoc """
  Parallel IMPLEMENT work (iteration 16 C2): how many tasks may run at once,
  set by the person in Settings. 1 keeps every task sequential, as before.
  """
  use Ecto.Migration

  def change do
    alter table(:agent_settings) do
      add :parallel_tasks, :integer, null: false, default: 1
    end

    alter table(:coordinator_dispatches) do
      # The tasks of a batch IMPLEMENT dispatch (C2); 1 for every other.
      add :task_count, :integer, null: false, default: 1
    end
  end
end
