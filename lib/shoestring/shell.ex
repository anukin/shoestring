defmodule Shoestring.Shell do
  @moduledoc "POSIX shell quoting for commands shown to the user."

  @safe ~r/\A[A-Za-z0-9_@%+=:,\.\/-]+\z/

  def argument(value) when is_binary(value) do
    if Regex.match?(@safe, value),
      do: value,
      else: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
