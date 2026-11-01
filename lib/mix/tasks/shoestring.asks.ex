defmodule Mix.Tasks.Shoestring.Asks do
  use Mix.Task
  @shortdoc "List what workers wait on you for, and allow or deny it"
  @moduledoc """
  `mix shoestring.asks` is `shoestring asks` run from the source checkout,
  with refusals raised as `Mix.Error`. bin/shoestring and the installed
  command run the same code (`Shoestring.CLI.Main`).

  #{Shoestring.CLI.Commands.Asks.help()}
  """

  @impl Mix.Task
  def run(args), do: Shoestring.CLI.Main.mix_task(Shoestring.CLI.Commands.Asks, args)
end
