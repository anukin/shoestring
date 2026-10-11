defmodule Pantry do
  def greeting(name), do: "Hello, " <> name <> "!"
  def total_cents(items), do: length(items)
  def receipt(items), do: "Items: #{length(items)}"
  def catalog(names) do
    names |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq() |> Enum.sort()
  end
end
