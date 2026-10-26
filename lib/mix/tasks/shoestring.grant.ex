defmodule Mix.Tasks.Shoestring.Grant do
  use Mix.Task
  @shortdoc "shoestring grant, from the source checkout"
  @moduledoc """
  `mix shoestring.grant` is `shoestring grant` run from the source checkout,
  with refusals raised as `Mix.Error`. bin/shoestring and the installed
  command run the same code (`Shoestring.CLI.Main`).

  #{Shoestring.CLI.Commands.Grant.help()}
  """

  @impl Mix.Task
  def run(args), do: Shoestring.CLI.Main.mix_task(Shoestring.CLI.Commands.Grant, args)
end
