defmodule Mix.Tasks.Shoestring.Review do
  use Mix.Task
  @shortdoc "List cross-reviews and decide the ones that wait for you"
  @moduledoc """
  `mix shoestring.review` is `shoestring review` run from the source checkout,
  with refusals raised as `Mix.Error`. bin/shoestring and the installed
  command run the same code (`Shoestring.CLI.Main`).

  #{Shoestring.CLI.Commands.Review.help()}
  """

  @impl Mix.Task
  def run(args), do: Shoestring.CLI.Main.mix_task(Shoestring.CLI.Commands.Review, args)
end
