defmodule Mix.Tasks.Shoestring.Models do
  use Mix.Task
  @shortdoc "List, refresh, enable or add the models agents may use"
  @moduledoc """
  `mix shoestring.models` is `shoestring models` run from the source checkout,
  with refusals raised as `Mix.Error`. bin/shoestring and the installed
  command run the same code (`Shoestring.CLI.Main`).

  #{Shoestring.CLI.Commands.Models.help()}
  """

  @impl Mix.Task
  def run(args), do: Shoestring.CLI.Main.mix_task(Shoestring.CLI.Commands.Models, args)
end
