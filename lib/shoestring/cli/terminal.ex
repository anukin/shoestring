defmodule Shoestring.CLI.Terminal do
  @moduledoc """
  Whether a person is at the keyboard. OTP reports, for standard I/O, whether
  stdin is a terminal (`:io.getopts/1`'s `stdin`). A command run by an agent
  through a tool, a pipe or a script has no terminal on stdin, so commands
  that must be a person's decision refuse there.
  """

  @doc "True when stdin is a terminal."
  def interactive? do
    Keyword.get(:io.getopts(:standard_io), :stdin, false) == true
  rescue
    _ -> false
  end
end
