defmodule Shoestring.Harness.ClaudeHeadless.PublicOutputTest do
  use ExUnit.Case, async: true
  alias Shoestring.Harness.ClaudeHeadless.EventNormalizer
  alias Shoestring.Harness.Security

  @run_id "00000000-0000-4000-8000-000000000003"
  @session "00000000-0000-4000-8000-000000000004"

  defp frame(type, content, extra \\ %{}) do
    Map.merge(
      %{"type" => type, "session_id" => @session, "message" => %{"content" => content}},
      extra
    )
  end

  test "retained text removes secret values while keeping surrounding prose" do
    text =
      "Use password: hunter2 and Bearer abcdefghijklmnop then sk-#{String.duplicate("x", 20)}."

    assert {:ok, [%{extensions: %{"claude-headless:output_text" => kept}}]} =
             EventNormalizer.normalize(
               frame("assistant", [%{"type" => "text", "text" => text}]),
               @run_id,
               1
             )

    refute kept =~ "hunter2"
    refute kept =~ "abcdefghijklmnop"
    refute kept =~ String.duplicate("x", 20)
    assert kept =~ "Use "
    assert kept =~ " then "
    refute Security.secret_value?(kept)
  end

  test "user text blocks are retained in full too" do
    text = String.duplicate("u", 1_000)

    assert {:ok, [%{kind: :output, extensions: %{"claude-headless:output_text" => ^text}}]} =
             EventNormalizer.normalize(
               frame("user", [%{"type" => "text", "text" => text}]),
               @run_id,
               1
             )
  end

  test "an oversized public block fails the run explicitly instead of truncating" do
    text = String.duplicate("o", 262_145)

    content = [
      %{"type" => "text", "text" => "short"},
      %{"type" => "text", "text" => text}
    ]

    assert {:ok, [event]} = EventNormalizer.normalize(frame("assistant", content), @run_id, 7)
    assert event.kind == :error
    assert event.error.category == :task_failed
    assert event.error.code == "output_oversized"
    assert event.extensions["claude-headless:terminal"] == true
    assert event.extensions["claude-headless:output_bytes"] == 262_145
    refute Map.has_key?(event.extensions, "claude-headless:output_text")
  end

  test "a block exactly at the bound is retained" do
    text = String.duplicate("b", 262_144)

    assert {:ok, [%{kind: :output, extensions: %{"claude-headless:output_text" => ^text}}]} =
             EventNormalizer.normalize(
               frame("assistant", [%{"type" => "text", "text" => text}]),
               @run_id,
               1
             )
  end

  test "tool stdio previews record truncation explicitly; short previews carry no flag" do
    stdout = String.duplicate("s", 600)

    content = [
      %{
        "type" => "tool_result",
        "tool_use_id" => "toolu_01",
        "content" => "ok",
        "is_error" => false
      }
    ]

    assert {:ok, [%{kind: :command, extensions: ext}]} =
             EventNormalizer.normalize(
               frame("user", content, %{
                 "tool_use_result" => %{"stdout" => stdout, "stderr" => "warn"}
               }),
               @run_id,
               1
             )

    assert ext["claude-headless:tool_stdout"] == String.duplicate("s", 500)
    assert ext["claude-headless:tool_stdout_truncated"] == true
    assert ext["claude-headless:tool_stdout_bytes"] == 600
    assert ext["claude-headless:tool_stderr"] == "warn"
    refute Map.has_key?(ext, "claude-headless:tool_stderr_truncated")
    assert ext["claude-headless:tool_result_text"] == "ok"
  end

  test "redact_retained has no diagnostic length limit and is idempotent" do
    text = String.duplicate("a", 5_000) <> " secret=value"
    once = Security.redact_retained(text)
    assert String.starts_with?(once, String.duplicate("a", 5_000))
    refute once =~ "value"
    assert Security.redact_retained(once) == once
    assert Security.redact_retained(nil) == ""
    assert String.length(Security.redact(text)) == 200
  end
end
