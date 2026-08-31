defmodule Shoestring.Harness.SystemIdentifier do
  @moduledoc false
  @behaviour Shoestring.Harness.Identifier

  @impl true
  def generate, do: Ecto.UUID.generate()
end
