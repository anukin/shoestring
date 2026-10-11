defmodule Pantry do
  def greeting(name) do
    trimmed = String.trim(name)
    "Hello, " <> if(trimmed == "", do: "friend", else: trimmed) <> "!"
  end
  def total_cents(items), do: length(items)
  def receipt(items), do: "Items: #{length(items)}"
  def catalog(names), do: names
end
