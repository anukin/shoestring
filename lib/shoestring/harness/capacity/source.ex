defmodule Shoestring.Harness.Capacity.Source do
  @moduledoc "Capacity observation behavior with explicit provenance and compatibility."

  alias Shoestring.Harness.{CapacitySnapshot, Error}

  @callback observe(map()) :: {:ok, CapacitySnapshot.t()} | {:error, Error.t()}
  @callback provenance() :: %{
              adapter_id: String.t(),
              provider_id: String.t(),
              invocation_mode: String.t(),
              event: atom()
            }
  @callback support_tier() ::
              :proactive | :conservative_partial | :reactive_only | :unsupported
end
