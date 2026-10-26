defmodule Mix.Tasks.Shoestring.Doctor do
  use Mix.Task
  @shortdoc "Check each agent CLI and the recorded models"
  @moduledoc """
  `mix shoestring.doctor` is `shoestring doctor` run from the source checkout,
  with refusals raised as `Mix.Error`. bin/shoestring and the installed
  command run the same code (`Shoestring.CLI.Main`).

  #{Shoestring.CLI.Commands.Doctor.help()}
  """

  @impl Mix.Task
  def run(args), do: Shoestring.CLI.Main.mix_task(Shoestring.CLI.Commands.Doctor, args)
end
