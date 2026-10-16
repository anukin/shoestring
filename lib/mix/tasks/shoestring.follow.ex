defmodule Mix.Tasks.Shoestring.Follow do
  use Mix.Task
  @shortdoc "Follow a goal's progress and answer what it waits for"
  @moduledoc """
      mix shoestring.follow GOAL [--by human:NAME]

  Prints the goal's progress from its durable history, asks you to confirm
  capacity when a task attempt is held for it, and prints the result when the
  goal completes. Interrupting it leaves the work running; run it again to
  re-attach. It never starts, stops or cancels work.
  """

  alias Shoestring.CLI.{Follow, Result, WorkLoop}

  @impl true
  def run(args) do
    case OptionParser.parse(args, strict: [by: :string]) do
      {opts, [goal], []} ->
        goal_id = cast!(goal)

        Shoestring.CLI.Repository.with_repo(fn _repo ->
          case Follow.run(goal_id, by: opts[:by] || WorkLoop.default_human()) do
            {:ok, :completed} -> Result.show(goal_id)
            {:ok, _} -> :ok
            {:error, reason} -> Mix.raise("Following stopped: #{inspect(reason)}")
          end
        end)

      _ ->
        Mix.raise("Invalid arguments. See mix help shoestring.follow")
    end
  end

  defp cast!(goal) do
    case Ecto.UUID.cast(goal) do
      {:ok, id} -> id
      :error -> Mix.raise("GOAL must be a goal id; see mix shoestring.goals list")
    end
  end
end
