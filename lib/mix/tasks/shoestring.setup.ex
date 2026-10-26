defmodule Mix.Tasks.Shoestring.Setup do
  use Mix.Task
  @shortdoc "Check the agent CLIs, record their models and save a default agent"
  @moduledoc """
  `mix shoestring.setup` is `shoestring setup` run from the source checkout,
  with refusals raised as `Mix.Error`. bin/shoestring and the installed
  command run the same code (`Shoestring.CLI.Main`).

  #{Shoestring.CLI.Commands.Setup.help()}
  """

  @impl Mix.Task
  def run(args), do: Shoestring.CLI.Main.mix_task(Shoestring.CLI.Commands.Setup, args)
end
