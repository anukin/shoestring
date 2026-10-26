defmodule Mix.Tasks.Shoestring.Dispatch do
  use Mix.Task
  @shortdoc "shoestring dispatch, from the source checkout"
  @moduledoc """
  `mix shoestring.dispatch` is `shoestring dispatch` run from the source checkout,
  with refusals raised as `Mix.Error`. bin/shoestring and the installed
  command run the same code (`Shoestring.CLI.Main`).

  #{Shoestring.CLI.Commands.Dispatch.help()}
  """

  @impl Mix.Task
  def run(args), do: Shoestring.CLI.Main.mix_task(Shoestring.CLI.Commands.Dispatch, args)
end
