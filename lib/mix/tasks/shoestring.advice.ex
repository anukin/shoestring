defmodule Mix.Tasks.Shoestring.Advice do
  use Mix.Task
  @shortdoc "shoestring advice, from the source checkout"
  @moduledoc """
  `mix shoestring.advice` is `shoestring advice` run from the source
  checkout, with refusals raised as `Mix.Error`. bin/shoestring and the
  installed command run the same code (`Shoestring.CLI.Main`).

  #{Shoestring.CLI.Commands.Advice.help()}
  """

  @impl Mix.Task
  def run(args), do: Shoestring.CLI.Main.mix_task(Shoestring.CLI.Commands.Advice, args)
end
