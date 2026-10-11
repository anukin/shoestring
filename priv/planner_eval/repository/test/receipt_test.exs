defmodule Pantry.ReceiptTest do
  use ExUnit.Case, async: true

  test "renders a receipt using the basket total" do
    assert Pantry.receipt([]) == "Total: 0 cents"
    assert Pantry.receipt([%{price_cents: 125, quantity: 2}, %{price_cents: 75, quantity: 3}]) == "Total: 475 cents"
  end
end
