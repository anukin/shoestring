defmodule Shoestring.Harness.Capacity.Registry.Entry do
  @moduledoc """
  A structured support matrix entry in the capacity compatibility registry.
  """

  @enforce_keys [
    :provider,
    :invocation_mode,
    :supported_tier,
    :tested_versions,
    :required_semantic_fields,
    :compatibility_outcome
  ]

  defstruct [
    :provider,
    :invocation_mode,
    :supported_tier,
    :tested_versions,
    :required_semantic_fields,
    :compatibility_outcome,
    :description
  ]

  @type t :: %__MODULE__{
          provider: atom(),
          invocation_mode: atom(),
          supported_tier: :proactive | :conservative_partial | :reactive_only | :unsupported,
          tested_versions: [String.t()],
          required_semantic_fields: [String.t()],
          compatibility_outcome: :compatible | :degraded | :incompatible,
          description: String.t() | nil
        }
end
