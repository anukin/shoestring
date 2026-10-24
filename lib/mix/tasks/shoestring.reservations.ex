defmodule Mix.Tasks.Shoestring.Reservations do
  use Mix.Task
  @shortdoc "Inspect configured reservations and queue evidence-backed recovery"
  @moduledoc """
  `mix shoestring.reservations` is `shoestring reservations` run from the source checkout,
  with refusals raised as `Mix.Error`. bin/shoestring and the installed
  command run the same code (`Shoestring.CLI.Main`).

  #{Shoestring.CLI.Commands.Reservations.help()}
  """

  @impl Mix.Task
  def run(args), do: Shoestring.CLI.Main.mix_task(Shoestring.CLI.Commands.Reservations, args)
end
