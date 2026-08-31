defmodule Shoestring.Harness.SystemClock do
  @moduledoc false
  @behaviour Shoestring.Harness.Clock

  @impl true
  def now, do: DateTime.utc_now()
end
