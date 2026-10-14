defmodule Shoestring.Harness.ClaudeHeadless.PublicOutputRegressionTest do
  use ExUnit.Case, async: true
  alias Shoestring.Harness.ClaudeHeadless.EventNormalizer

  @run_id "00000000-0000-4000-8000-000000000003"

  defp assistant(text) do
    %{
      "type" => "assistant",
      "session_id" => "00000000-0000-4000-8000-000000000004",
      "message" => %{"content" => [%{"type" => "text", "text" => text}]}
    }
  end

  test "public assistant text is retained in full, not as a 500-character preview" do
    text = String.duplicate("Retained public output. ", 100)
    assert byte_size(text) == 2_400

    assert {:ok, [%{kind: :output, extensions: extensions}]} =
             EventNormalizer.normalize(assistant(text), @run_id, 1, %{})

    # The baseline keeps only the first 500 characters.
    assert extensions["claude-headless:output_text"] == text
  end

  test "a credential marker is redacted instead of discarding the public output event" do
    text = "Configure the token: abc123def before running the gate."

    # The baseline drops this whole event because the value trips the secret filter.
    assert {:ok, [%{kind: :output, extensions: extensions}]} =
             EventNormalizer.normalize(assistant(text), @run_id, 1, %{})

    assert extensions["claude-headless:output_text"] ==
             "Configure the [REDACTED] before running the gate."
  end
end
