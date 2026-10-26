defmodule Mix.Tasks.Shoestring.Capacity do
  use Mix.Task
  @shortdoc "shoestring capacity, from the source checkout"
  @moduledoc """
  `mix shoestring.capacity` is `shoestring capacity` run from the source
  checkout, with refusals raised as `Mix.Error`. bin/shoestring and the
  installed command run the same code (`Shoestring.CLI.Main`).

  #{Shoestring.CLI.Commands.Capacity.help()}
  """

  @impl Mix.Task
  def run(args), do: Shoestring.CLI.Main.mix_task(Shoestring.CLI.Commands.Capacity, args)
end
