defmodule Shoestring.CLI.Commands.Checks do
  @moduledoc "`shoestring checks`: the checks a goal ran, with their exact results."

  alias Shoestring.CLI.{Checks, Refusal}

  @help """
  shoestring checks GOAL [--json]
  shoestring checks GOAL --output N [--json]

  Every check (gate) recorded for GOAL, in the order it ran: the task and
  attempt (or the goal's final checks), the check, its kind and whether it is
  required, the exact result and exit status, its duration, the commit it
  verified and the identity of its versioned specification. `--output N`
  prints the stored (redacted) output of check N: the bytes on stdout, its
  description on stderr. Nothing runs. `--json` prints one JSON object (see
  docs/cli-output.md).
  """

  def help, do: @help

  def run(args, context) do
    with {opts, [goal], []} <-
           OptionParser.parse(args, strict: [output: :integer, json: :boolean]),
         {:ok, goal_id} <- Ecto.UUID.cast(goal) do
      context.with_repo.(fn _repo ->
        case Checks.show(goal_id,
               output: opts[:output],
               json: opts[:json] == true,
               shell: context.shell
             ) do
          :ok ->
            :ok

          {:error, :no_such_check} ->
            Refusal.refuse!("No check #{opts[:output]} for this goal.")

          {:error, :no_output_recorded} ->
            Refusal.refuse!("Check #{opts[:output]} recorded no output.")

          {:error, reason} ->
            Refusal.refuse!("Output unavailable: #{inspect(reason)}")
        end
      end)
    else
      _ -> Refusal.usage!("checks")
    end
  end
end
