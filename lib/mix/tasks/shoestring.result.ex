defmodule Mix.Tasks.Shoestring.Result do
  use Mix.Task
  @shortdoc "Show a completed goal's verified result and how to take it"
  @moduledoc """
  `mix shoestring.result` is `shoestring result` run from the source checkout,
  with refusals raised as `Mix.Error`. bin/shoestring and the installed
  command run the same code (`Shoestring.CLI.Main`).

  #{Shoestring.CLI.Commands.Result.help()}
  """

  @impl Mix.Task
  def run(args), do: Shoestring.CLI.Main.mix_task(Shoestring.CLI.Commands.Result, args)
end
