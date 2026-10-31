defmodule Shoestring.Dispatches.Explore.ProgressTest do
  use ExUnit.Case, async: true

  alias Shoestring.Dispatches.Explore.Progress

  defp steps(chunks, parse) do
    test = self()
    report = &send(test, {:step, &1})
    Enum.reduce(chunks, "", &Progress.feed(&2, &1, parse, report))
    collect([])
  end

  defp collect(acc) do
    receive do
      {:step, step} -> collect([step | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "Codex commands are reported as they start, across chunk boundaries" do
    started =
      Jason.encode!(%{
        "type" => "item.started",
        "item" => %{"type" => "command_execution", "command" => "/bin/zsh -c 'cat README.md'"}
      })

    completed =
      Jason.encode!(%{"type" => "item.completed", "item" => %{"type" => "agent_message"}})

    {head, tail} = String.split_at(started, 20)

    assert steps([head, tail <> "\n" <> completed <> "\n", "not json\n"], &Progress.codex/1) ==
             ["Ran /bin/zsh -c 'cat README.md'"]
  end

  test "Claude tool uses name their target; text and other frames are not steps" do
    frame =
      Jason.encode!(%{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{"type" => "text", "text" => "Looking"},
            %{"type" => "tool_use", "name" => "Read", "input" => %{"file_path" => "lib/a.ex"}},
            %{"type" => "tool_use", "name" => "Grep", "input" => %{"pattern" => "def add"}},
            %{"type" => "tool_use", "name" => "Glob", "input" => %{}}
          ]
        }
      })

    assert steps([frame <> "\n"], &Progress.claude/1) == ["Read lib/a.ex", "Grep def add", "Glob"]
  end

  test "steps are redacted and bounded, and nothing is parsed without a report" do
    command =
      "curl -H 'Authorization: Bearer sk-live-abcdef1234567890' " <> String.duplicate("x", 400)

    frame =
      Jason.encode!(%{
        "type" => "item.started",
        "item" => %{"type" => "command_execution", "command" => command}
      })

    assert [step] = steps([frame <> "\n"], &Progress.codex/1)
    refute step =~ "sk-live-abcdef1234567890"
    assert String.length(step) == 200
    assert String.ends_with?(step, "…")

    assert Progress.feed("", frame <> "\n", &Progress.codex/1, nil) == ""
  end
end
