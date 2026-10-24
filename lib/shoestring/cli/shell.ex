defmodule Shoestring.CLI.Shell do
  @moduledoc """
  The terminal for `shoestring` commands, without Mix.

  The output contract: `info/1` writes data (IDs, results, JSON) to stdout;
  `error/1` writes everything else (messages, progress, prompts' context and
  errors) to stderr. `prompt/1` asks on stderr and reads a line from stdin.
  The function names follow `Mix.Shell`, so tests drive commands with
  `Mix.Shell.Process`, where `:info` is stdout and `:error` is stderr.
  """

  @doc "Writes one line of data to stdout."
  def info(message), do: IO.puts(:stdio, message)

  @doc "Writes one line of messages or progress to stderr."
  def error(message), do: IO.puts(:stderr, message)

  @doc "Asks on stderr and returns the line read from stdin (empty at end of input)."
  def prompt(message) do
    IO.write(:stderr, message)

    case IO.gets(:stdio, "") do
      line when is_binary(line) -> line
      _ -> ""
    end
  end
end
