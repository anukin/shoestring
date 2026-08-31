defmodule Shoestring.Test.FixedIdentifier do
  @behaviour Shoestring.Harness.Identifier

  @impl true
  def generate, do: "00000000-0000-4000-8000-000000000099"
end
