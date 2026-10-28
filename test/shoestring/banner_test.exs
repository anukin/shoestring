defmodule Shoestring.BannerTest do
  use ExUnit.Case, async: true

  test "the banner is a small ASCII shoe with the version and the address" do
    text = Shoestring.Banner.text("http://localhost:4000")
    version = :shoestring |> Application.spec(:vsn) |> to_string()

    assert text =~ "shoestring #{version} at http://localhost:4000"
    assert text =~ "x x x"
    assert String.printable?(text)
    assert Enum.all?(String.to_charlist(text), &(&1 in 0..127))

    lines = String.split(text, "\n", trim: true)
    assert length(lines) <= 8
    assert Enum.all?(lines, &(String.length(&1) <= 60))
  end
end
