defmodule Shoestring.Harness.Dispatch.UnconfiguredEffect do
  @moduledoc false

  @behaviour Shoestring.Harness.Dispatch.Effect

  @impl true
  def perform(_run, _dispatch), do: {:error, :dispatch_effect_not_configured}
end
