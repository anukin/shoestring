defmodule Pantry.GreetingTest do
  use ExUnit.Case, async: true

  test "trims names and substitutes a blank name" do
    assert Pantry.greeting("  Sam  ") == "Hello, Sam!"
    assert Pantry.greeting("   ") == "Hello, friend!"
    assert Pantry.greeting("Jo") == "Hello, Jo!"
  end
end
