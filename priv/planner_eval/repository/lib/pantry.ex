defmodule Pantry do
  def greeting(name), do: "Hello, " <> name <> "!"
  def total_cents(items), do: length(items)
  def receipt(items), do: "Items: #{length(items)}"
  def catalog(names), do: names
end
