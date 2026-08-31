defmodule Shoestring.Test.CapabilityAdapter do
  @behaviour Shoestring.Harness.Adapter

  alias Shoestring.Harness.Identity

  @impl true
  def identity do
    {:ok, identity} =
      Identity.new(%{
        adapter_id: "test.adapter",
        provider: "test",
        adapter_version: "1.0.0",
        schema_version: 1,
        invocation_mode: :fake
      })

    identity
  end

  @impl true
  def capabilities, do: MapSet.new([:cancel])

  @impl true
  def probe(_opts), do: raise("not used by capability tests")

  @impl true
  def start(_request, _opts), do: raise("not used by capability tests")

  @impl true
  def cancel(_identity, _opts), do: {:ok, :cancelled}

  @impl true
  def status(_identity, _opts), do: {:ok, %{state: :running}}

  @impl true
  def stream(_identity, _opts), do: {:ok, []}
end
