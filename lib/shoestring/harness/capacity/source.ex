defmodule Shoestring.Harness.Capacity.Source do
  @moduledoc "Capacity observation behavior with explicit provenance and compatibility."

  alias Shoestring.Harness.{CapacitySnapshot, Error}

  @callback observe(map()) :: {:ok, CapacitySnapshot.t()} | {:error, Error.t()}
  @callback provenance() :: %{adapter_id: String.t(), method: String.t()}
  @callback support_tier() :: :supported | :partial | :unsupported
end
