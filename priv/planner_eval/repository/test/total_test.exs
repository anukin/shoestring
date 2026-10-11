defmodule Pantry.TotalTest do
  use ExUnit.Case, async: true

  test "sums integer cent prices with quantities, including an empty basket" do
    assert Pantry.total_cents([]) == 0
    assert Pantry.total_cents([%{price_cents: 125, quantity: 2}, %{price_cents: 75, quantity: 3}]) == 475
  end
end
