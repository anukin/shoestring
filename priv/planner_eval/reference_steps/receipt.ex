defmodule Pantry do
  def greeting(name), do: "Hello, " <> name <> "!"
  def total_cents(items), do: Enum.sum(Enum.map(items, &(&1.price_cents * &1.quantity)))
  def receipt(items), do: "Total: #{total_cents(items)} cents"
  def catalog(names), do: names
end
