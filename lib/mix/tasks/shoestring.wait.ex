defmodule Mix.Tasks.Shoestring.Wait do
  use Mix.Task
  @shortdoc "shoestring wait, from the source checkout"
  @moduledoc """
  `mix shoestring.wait` is `shoestring wait` run from the source checkout,
  with refusals raised as `Mix.Error`. bin/shoestring and the installed
  command run the same code (`Shoestring.CLI.Main`).

  #{Shoestring.CLI.Commands.Wait.help()}
  """

  @impl Mix.Task
  def run(args), do: Shoestring.CLI.Main.mix_task(Shoestring.CLI.Commands.Wait, args)
end
