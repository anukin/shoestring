defmodule Mix.Tasks.Shoestring.Agents do
  use Mix.Task
  @shortdoc "List, read, create or change saved agents"
  @moduledoc """
  `mix shoestring.agents` is `shoestring agents` run from the source checkout,
  with refusals raised as `Mix.Error`. bin/shoestring and the installed
  command run the same code (`Shoestring.CLI.Main`).

  #{Shoestring.CLI.Commands.Agents.help()}
  """

  @impl Mix.Task
  def run(args), do: Shoestring.CLI.Main.mix_task(Shoestring.CLI.Commands.Agents, args)
end
