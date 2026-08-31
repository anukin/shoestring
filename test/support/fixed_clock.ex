defmodule Shoestring.Test.FixedClock do
  @behaviour Shoestring.Harness.Clock

  @impl true
  def now, do: ~U[2026-08-30 12:00:00.000000Z]
end
