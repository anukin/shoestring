defmodule Mix.Tasks.Shoestring do
  use Mix.Task
  @shortdoc "Run a shoestring command from the source checkout"
  @moduledoc """
      mix shoestring COMMAND [ARGS...]

  What the checkout's `bin/shoestring` runs: the same commands, arguments,
  output and exit status as the installed `shoestring` (`Shoestring.CLI.Main`),
  against the checkout's state. `SHOESTRING_CALLER_DIR` names the directory
  relative paths and `do`'s repository resolve against (bin/shoestring sets it
  to where you ran it). `mix shoestring help` lists the commands.
  """

  @impl Mix.Task
  def run(args) do
    Shoestring.CLI.Main.log_to_stderr()

    status =
      Shoestring.CLI.Main.run(args,
        installation: :checkout,
        cwd: System.get_env("SHOESTRING_CALLER_DIR") || File.cwd!()
      )

    if status != 0, do: exit({:shutdown, status})
  end
end
