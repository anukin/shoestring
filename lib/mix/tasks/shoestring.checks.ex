defmodule Mix.Tasks.Shoestring.Checks do
  use Mix.Task
  @shortdoc "List the checks a goal ran, with their exact results"
  @moduledoc """
  `mix shoestring.checks` is `shoestring checks` run from the source checkout,
  with refusals raised as `Mix.Error`. bin/shoestring and the installed
  command run the same code (`Shoestring.CLI.Main`).

  #{Shoestring.CLI.Commands.Checks.help()}
  """

  @impl Mix.Task
  def run(args), do: Shoestring.CLI.Main.mix_task(Shoestring.CLI.Commands.Checks, args)
end
