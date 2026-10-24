defmodule Mix.Tasks.Shoestring.Do do
  use Mix.Task
  @shortdoc "Plan, approve and run a request in a Git repository"
  @moduledoc """
  `mix shoestring.do` is `shoestring do` run from the source checkout,
  with refusals raised as `Mix.Error`. bin/shoestring and the installed
  command run the same code (`Shoestring.CLI.Main`).

  #{Shoestring.CLI.Commands.Do.help()}
  """

  @impl Mix.Task
  def run(args), do: Shoestring.CLI.Main.mix_task(Shoestring.CLI.Commands.Do, args)
end
