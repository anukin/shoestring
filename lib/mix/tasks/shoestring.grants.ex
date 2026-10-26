defmodule Mix.Tasks.Shoestring.Grants do
  use Mix.Task
  @shortdoc "shoestring grants, from the source checkout"
  @moduledoc """
  `mix shoestring.grants` is `shoestring grants` run from the source checkout,
  with refusals raised as `Mix.Error`. bin/shoestring and the installed
  command run the same code (`Shoestring.CLI.Main`).

  #{Shoestring.CLI.Commands.Grants.help()}
  """

  @impl Mix.Task
  def run(args), do: Shoestring.CLI.Main.mix_task(Shoestring.CLI.Commands.Grants, args)
end
