defmodule Mix.Tasks.Shoestring.Execution do
  use Mix.Task
  @shortdoc "Start or inspect durable approved-plan execution"
  @moduledoc """
  `mix shoestring.execution` is `shoestring execution` run from the source checkout,
  with refusals raised as `Mix.Error`. bin/shoestring and the installed
  command run the same code (`Shoestring.CLI.Main`).

  #{Shoestring.CLI.Commands.Execution.help()}
  """

  @impl Mix.Task
  def run(args), do: Shoestring.CLI.Main.mix_task(Shoestring.CLI.Commands.Execution, args)
end
