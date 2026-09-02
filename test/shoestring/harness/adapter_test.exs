defmodule Shoestring.Harness.AdapterTest do
  use ExUnit.Case, async: true

  alias Shoestring.Harness.Adapter

  test "capability discovery governs optional operations" do
    adapter = Shoestring.Test.CapabilityAdapter

    assert Adapter.supports?(adapter, :cancel)
    assert Adapter.supports?(adapter, :resume)
    refute Adapter.supports?(adapter, :send)

    assert {:ok, :cancelled} = Adapter.invoke_optional(adapter, :cancel, :cancel, [nil, %{}])

    assert {:error, %{category: :unsupported_capability, code: "capability_not_supported"}} =
             Adapter.invoke_optional(adapter, :send, :send, [nil, "msg", %{}])
  end
end
