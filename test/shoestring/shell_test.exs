defmodule Shoestring.ShellTest do
  use ExUnit.Case, async: true

  test "displayed shell arguments preserve spaces, quotes, metacharacters and empty strings" do
    for value <- [
          "/copy with spaces",
          "/copy's repo",
          "$(printf injected)",
          "`printf injected`",
          "",
          "shoestring/run-123"
        ] do
      command = "set -- " <> Shoestring.Shell.argument(value) <> "; printf '%s\\n' \"$#\" \"$1\""
      assert System.cmd("sh", ["-c", command]) == {"1\n" <> value <> "\n", 0}
    end
  end
end
