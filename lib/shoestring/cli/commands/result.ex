defmodule Shoestring.CLI.Commands.Result do
  @moduledoc "`shoestring result`: a completed goal's verified result and how to take it."

  alias Shoestring.CLI.{Command, Refusal, Result}

  @help """
  shoestring result GOAL [--json]

  For a completed goal: the final commit, the checks recorded at completion,
  a diff stat against the approved base, and the exact `git fetch` and
  `git merge` commands to take the work into your repository. Shoestring
  never runs them for you. `--json` prints the same as one JSON object (see
  docs/cli-output.md).
  """

  def help, do: @help

  def run(args, context) do
    with {opts, [goal], []} <- OptionParser.parse(args, strict: [json: :boolean]),
         {:ok, goal_id} <- Ecto.UUID.cast(goal) do
      context.with_repo.(fn _repo ->
        case Result.fetch(goal_id) do
          {:ok, result} ->
            if opts[:json],
              do: Command.json(context, result),
              else: Result.print(result, context.shell)

            :ok

          {:error, :not_completed} ->
            Refusal.refuse!("The goal has not completed yet.")

          {:error, reason} ->
            Refusal.refuse!("No result: #{inspect(reason)}")
        end
      end)
    else
      _ -> Refusal.usage!("result")
    end
  end
end
