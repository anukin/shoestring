defmodule Mix.Tasks.Shoestring.Lessons do
  use Mix.Task
  @shortdoc "List lessons, and approve, reject or retire them"
  @moduledoc """
  `mix shoestring.lessons` is `shoestring lessons` run from the source
  checkout, with refusals raised as `Mix.Error`. bin/shoestring and the
  installed command run the same code (`Shoestring.CLI.Main`).

  #{Shoestring.CLI.Commands.Lessons.help()}
  """

  @impl Mix.Task
  def run(args), do: Shoestring.CLI.Main.mix_task(Shoestring.CLI.Commands.Lessons, args)
end
