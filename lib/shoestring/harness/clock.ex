defmodule Shoestring.Harness.Clock do
  @moduledoc "Injected time source for deterministic harness code."

  @callback now() :: DateTime.t()

  @spec now(module()) :: DateTime.t()
  def now(clock) when is_atom(clock) do
    clock.now() |> DateTime.truncate(:microsecond)
  end
end
