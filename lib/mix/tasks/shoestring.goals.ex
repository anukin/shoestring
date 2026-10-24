defmodule Mix.Tasks.Shoestring.Goals do
  use Mix.Task
  @shortdoc "Create a goal or list goals"
  @moduledoc """
  `mix shoestring.goals` is `shoestring goals` run from the source checkout,
  with refusals raised as `Mix.Error`. bin/shoestring and the installed
  command run the same code (`Shoestring.CLI.Main`).

  #{Shoestring.CLI.Commands.Goals.help()}
  """

  @impl Mix.Task
  def run(args), do: Shoestring.CLI.Main.mix_task(Shoestring.CLI.Commands.Goals, args)
end
