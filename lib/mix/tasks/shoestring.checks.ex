defmodule Mix.Tasks.Shoestring.Checks do
  use Mix.Task
  @shortdoc "List the checks a goal ran, with their exact results"
  @moduledoc """
      mix shoestring.checks GOAL
      mix shoestring.checks GOAL --output N

  Every check (gate) recorded for GOAL, in the order it ran: the task and
  attempt (or the goal's final checks), the check, its kind and whether it is
  required, the exact result and exit status, its duration, the commit it
  verified and the identity of its versioned specification. `--output N`
  prints the stored (redacted) output of check N. Nothing runs.
  """

  alias Shoestring.CLI.Checks

  @impl true
  def run(args) do
    with {opts, [goal], []} <- OptionParser.parse(args, strict: [output: :integer]),
         {:ok, goal_id} <- Ecto.UUID.cast(goal) do
      Shoestring.CLI.Repository.with_repo(fn _repo ->
        case Checks.show(goal_id, output: opts[:output]) do
          :ok -> :ok
          {:error, :no_such_check} -> Mix.raise("No check #{opts[:output]} for this goal.")
          {:error, :no_output_recorded} -> Mix.raise("Check #{opts[:output]} recorded no output.")
          {:error, reason} -> Mix.raise("Output unavailable: #{inspect(reason)}")
        end
      end)
    else
      _ -> Mix.raise("Invalid arguments. See mix help shoestring.checks")
    end
  end
end
