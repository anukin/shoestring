defmodule Pantry.CatalogTest do
  use ExUnit.Case, async: true

  test "trims, removes blanks, deduplicates and sorts case-sensitive names" do
    assert Pantry.catalog([" pear ", "Apple", "", "pear", "  ", "apple"]) == ["Apple", "apple", "pear"]
    assert Pantry.catalog([]) == []
  end
end
