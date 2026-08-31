defmodule Shoestring.Harness.Identifier do
  @moduledoc "Injected identifier source for deterministic harness code."

  @callback generate() :: Ecto.UUID.t()

  @spec generate(module()) :: Ecto.UUID.t()
  def generate(identifier) when is_atom(identifier), do: identifier.generate()
end
