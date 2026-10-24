defmodule Mix.Tasks.Shoestring.Follow do
  use Mix.Task
  @shortdoc "Follow a goal's progress and answer what it waits for"
  @moduledoc """
  `mix shoestring.follow` is `shoestring follow` run from the source checkout,
  with refusals raised as `Mix.Error`. bin/shoestring and the installed
  command run the same code (`Shoestring.CLI.Main`).

  #{Shoestring.CLI.Commands.Follow.help()}
  """

  @impl Mix.Task
  def run(args), do: Shoestring.CLI.Main.mix_task(Shoestring.CLI.Commands.Follow, args)
end
