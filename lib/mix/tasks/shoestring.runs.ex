defmodule Mix.Tasks.Shoestring.Runs do
  use Mix.Task
  @shortdoc "shoestring runs, from the source checkout"
  @moduledoc """
  `mix shoestring.runs` is `shoestring runs` run from the source checkout,
  with refusals raised as `Mix.Error`. bin/shoestring and the installed
  command run the same code (`Shoestring.CLI.Main`).

  #{Shoestring.CLI.Commands.Runs.help()}
  """

  @impl Mix.Task
  def run(args), do: Shoestring.CLI.Main.mix_task(Shoestring.CLI.Commands.Runs, args)
end
