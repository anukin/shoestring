defmodule Mix.Tasks.Shoestring.Plans do
  use Mix.Task
  @shortdoc "Inspect, edit and decide immutable goal plan revisions without dispatch"
  @moduledoc """
  `mix shoestring.plans` is `shoestring plans` run from the source checkout,
  with refusals raised as `Mix.Error`. bin/shoestring and the installed
  command run the same code (`Shoestring.CLI.Main`).

  #{Shoestring.CLI.Commands.Plans.help()}
  """

  @impl Mix.Task
  def run(args), do: Shoestring.CLI.Main.mix_task(Shoestring.CLI.Commands.Plans, args)
end
