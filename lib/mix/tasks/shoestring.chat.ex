defmodule Mix.Tasks.Shoestring.Chat do
  use Mix.Task
  @shortdoc "Prepare a coordinator session (bin/shoestring chat starts it)"
  @moduledoc """
  `mix shoestring.chat` is `shoestring chat` run from the source checkout,
  with refusals raised as `Mix.Error`. It prepares the session and prints
  the launch instead of starting it: Mix cannot hand its terminal to the
  coordinator, so use `bin/shoestring chat`, which execs the launch script.

  #{Shoestring.CLI.Commands.Chat.help()}
  """

  @impl Mix.Task
  def run(args), do: Shoestring.CLI.Main.mix_task(Shoestring.CLI.Commands.Chat, args)
end
