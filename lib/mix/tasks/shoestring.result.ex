defmodule Mix.Tasks.Shoestring.Result do
  use Mix.Task
  @shortdoc "Show a completed goal's verified result and how to take it"
  @moduledoc """
      mix shoestring.result GOAL

  For a completed goal: the final commit, the checks recorded at completion,
  a diff stat against the approved base, and the exact `git fetch` and
  `git merge` commands to take the work into your repository. Shoestring
  never runs them for you.
  """

  alias Shoestring.CLI.Result

  @impl true
  def run(args) do
    with {[], [goal], []} <- OptionParser.parse(args, strict: []),
         {:ok, goal_id} <- Ecto.UUID.cast(goal) do
      Shoestring.CLI.Repository.with_repo(fn _repo ->
        case Result.show(goal_id) do
          {:ok, _} -> :ok
          {:error, :not_completed} -> Mix.raise("The goal has not completed yet.")
          {:error, reason} -> Mix.raise("No result: #{inspect(reason)}")
        end
      end)
    else
      _ -> Mix.raise("Invalid arguments. See mix help shoestring.result")
    end
  end
end
