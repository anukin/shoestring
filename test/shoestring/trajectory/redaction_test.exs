defmodule Shoestring.Trajectory.RedactionTest do
  use ExUnit.Case, async: true

  alias Shoestring.Trajectory.Redaction

  test "redacts secret keys and bearer tokens without consuming following punctuation" do
    value = %{
      "authorization" => "Bearer abc/def+=-?public=1",
      "nested" => %{"password" => "keep-this-private"},
      "message" => "Bearer abc/def+=-?public=1",
      "safe" => "?public=1"
    }

    assert Redaction.redact(value) == %{
             "authorization" => "[REDACTED]",
             "nested" => %{"password" => "[REDACTED]"},
             "message" => "[REDACTED]?public=1",
             "safe" => "?public=1"
           }
  end

  test "redacts binaries recursively while leaving non-secret bytes exact" do
    bytes = <<0, 1, 2, 255>>

    assert Redaction.redact(%{"bytes_base64" => Base.encode64(bytes)}) == %{
             "bytes_base64" => Base.encode64(bytes)
           }
  end
end
