defmodule Shoestring.Harness.Identity do
  @moduledoc "Stable, vendor-neutral harness identity and compatibility declaration."

  alias Shoestring.Harness.Contract

  @enforce_keys [:adapter_id, :provider, :adapter_version, :schema_version, :invocation_mode]
  defstruct [:adapter_id, :provider, :adapter_version, :schema_version, :invocation_mode]

  @type t :: %__MODULE__{
          adapter_id: String.t(),
          provider: String.t(),
          adapter_version: String.t(),
          schema_version: pos_integer(),
          invocation_mode: :process | :api | :fake
        }

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attrs) when is_map(attrs) do
    with {:ok, adapter_id} <-
           attrs
           |> Contract.required(:adapter_id)
           |> then(&Contract.text(&1, :adapter_id, max: 200)),
         {:ok, provider} <-
           attrs |> Contract.required(:provider) |> then(&Contract.text(&1, :provider, max: 200)),
         {:ok, adapter_version} <-
           attrs
           |> Contract.required(:adapter_version)
           |> then(&Contract.text(&1, :adapter_version, max: 100)),
         {:ok, schema_version} <-
           attrs
           |> Contract.required(:schema_version)
           |> then(&Contract.positive_integer(&1, :schema_version)),
         {:ok, invocation_mode} <-
           attrs
           |> Contract.required(:invocation_mode)
           |> then(&Contract.enum(&1, :invocation_mode, [:process, :api, :fake])) do
      {:ok,
       %__MODULE__{
         adapter_id: adapter_id,
         provider: provider,
         adapter_version: adapter_version,
         schema_version: schema_version,
         invocation_mode: invocation_mode
       }}
    end
  end

  def new(_attrs), do: Contract.invalid(:base, "must be an object")
end
