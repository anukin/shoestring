defmodule Shoestring.BrowserTest do
  @moduledoc "Opening the web UI when `shoestring start` serves (iteration 16): only when allowed."
  use ExUnit.Case, async: true

  alias Shoestring.Browser

  defp env(value), do: fn "SHOESTRING_OPEN_BROWSER" -> value end

  test "opens only when started from a terminal and Settings allow it" do
    me = self()
    opener = fn url -> send(me, {:opened, url}) end

    assert :opened =
             Browser.open_on_start("http://127.0.0.1:4000",
               env: env("1"),
               allowed?: true,
               opener: opener
             )

    assert_receive {:opened, "http://127.0.0.1:4000"}

    for {value, allowed?} <- [{"0", true}, {nil, true}, {"1", false}] do
      assert :skipped =
               Browser.open_on_start("http://127.0.0.1:4000",
                 env: env(value),
                 allowed?: allowed?,
                 opener: opener
               )
    end

    refute_receive {:opened, _}
  end

  test "the release wrapper decides from the terminal, and --no-open never opens" do
    wrapper = File.read!("rel/overlays/bin/shoestringctl")
    assert wrapper =~ "--no-open) export SHOESTRING_OPEN_BROWSER=0"
    assert wrapper =~ "if test -t 1; then export SHOESTRING_OPEN_BROWSER=1"
  end
end
