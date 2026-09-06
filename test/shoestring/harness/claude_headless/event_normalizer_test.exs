defmodule Shoestring.Harness.ClaudeHeadless.EventNormalizerTest do
  @moduledoc """
  Parser tests built on the committed live captures in
  `plans/evidence/04-single-elf/fixtures/claude/` (all claims VERIFIED —
  see `plans/evidence/04-single-elf/claude-exec-events.md`).
  """

  use ExUnit.Case, async: true

  alias Shoestring.Harness.ClaudeHeadless.EventNormalizer

  @fixture_dir "plans/evidence/04-single-elf/fixtures/claude"
  @run_id "00000000-0000-4000-8000-000000000003"

  defp read_frames(name) do
    path = Path.join(@fixture_dir, name)

    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp normalize_all(frames) do
    {events, _} =
      Enum.reduce(frames, {[], 1}, fn frame, {acc, ord} ->
        case EventNormalizer.normalize(frame, @run_id, ord, %{}) do
          {:ok, normalized} -> {acc ++ normalized, ord + length(normalized)}
          {:skip, _} -> {acc, ord}
          {:error, _} -> {acc, ord}
        end
      end)

    events
  end

  describe "tool-exec capture (8 frames, exit 0)" do
    setup do
      frames = read_frames("stream-json-tool-exec.jsonl")
      assert length(frames) == 8
      {:ok, frames: frames, events: normalize_all(frames)}
    end

    test "every frame normalizes: init, quota status, 2 starts, 2 ends, text, result", %{
      events: events
    } do
      kinds = Enum.map(events, & &1.kind)

      assert kinds == [
               :lifecycle,
               :lifecycle,
               :command,
               :command,
               :command,
               :command,
               :output,
               :result
             ]

      commands = Enum.filter(events, &(&1.kind == :command))
      boundaries = Enum.map(commands, & &1.extensions["claude-headless:boundary"])
      assert boundaries == ["start", "start", "end", "end"]
    end

    test "tool boundaries correlate ONLY by toolu_ id, not by adjacency or message id", %{
      frames: frames,
      events: events
    } do
      # Both STARTs precede both ENDs in the capture — no alternation.
      assert Enum.at(frames, 2)["type"] == "assistant"
      assert Enum.at(frames, 3)["type"] == "assistant"
      assert Enum.at(frames, 4)["type"] == "user"
      assert Enum.at(frames, 5)["type"] == "user"

      # Lines 2-3 share one message.id / request_id across different tools.
      assert Enum.at(frames, 2)["message"]["id"] == Enum.at(frames, 3)["message"]["id"]
      assert Enum.at(frames, 2)["request_id"] == Enum.at(frames, 3)["request_id"]

      commands = Enum.filter(events, &(&1.kind == :command))

      starts = Enum.filter(commands, &(&1.extensions["claude-headless:boundary"] == "start"))
      ends = Enum.filter(commands, &(&1.extensions["claude-headless:boundary"] == "end"))

      assert Enum.map(starts, & &1.extensions["claude-headless:tool_use_id"]) == [
               "toolu_000000000000000000000001",
               "toolu_000000000000000000000002"
             ]

      assert Enum.map(ends, & &1.extensions["claude-headless:tool_use_id"]) == [
               "toolu_000000000000000000000001",
               "toolu_000000000000000000000002"
             ]

      for s <- starts do
        assert Enum.any?(
                 ends,
                 &(&1.extensions["claude-headless:tool_use_id"] ==
                     s.extensions["claude-headless:tool_use_id"])
               )
      end

      [first_start, second_start] = starts
      assert first_start.extensions["claude-headless:tool_name"] == "Bash"
      assert first_start.extensions["claude-headless:command"] =~ "hello.txt"
      assert second_start.extensions["claude-headless:command"] == "printf ok"

      [first_end | _] = ends
      assert first_end.extensions["claude-headless:status"] == "completed"
      assert first_end.extensions["claude-headless:is_error"] == false
      assert first_end.extensions["claude-headless:tool_stdout"] == "hello"
    end

    test "session id is top-level on every frame and propagates to every event", %{
      frames: frames,
      events: events
    } do
      session_ids = frames |> Enum.map(& &1["session_id"]) |> Enum.uniq()
      assert session_ids == ["aaaaaaaa-0000-4000-a000-000000000002"]

      for event <- events do
        assert event.provider_session_id == "aaaaaaaa-0000-4000-a000-000000000002"
        assert event.run_id == @run_id
      end
    end

    test "success result keys on terminal_reason completed, not on subtype", %{events: events} do
      [result] = Enum.filter(events, &(&1.kind == :result))
      assert result.result == %{status: "completed", artifact_id: nil}
      assert result.extensions["claude-headless:terminal_reason"] == "completed"
    end

    test "rate_limit_event is a status signal, never a quota refusal", %{events: events} do
      [quota] =
        Enum.filter(
          events,
          &(&1.extensions["claude-headless:frame_type"] == "rate_limit_event")
        )

      assert quota.kind == :lifecycle
      assert quota.extensions["claude-headless:rate_limit_status"] == "allowed"
      assert quota.extensions["claude-headless:rate_limit_type"] == "five_hour"
    end

    test "events are ordinal-ordered and secret-free", %{events: events} do
      ordinals = Enum.map(events, & &1.ordinal)
      assert ordinals == Enum.sort(ordinals)
      assert ordinals == Enum.to_list(1..length(events))

      blob = inspect(events)
      refute blob =~ "sk-ant-"
      refute blob =~ "Bearer "
    end
  end

  describe "auth-failure capture (exit 1, subtype lies)" do
    test "is_error with subtype success normalizes to :task_failed error, never :quota_refused" do
      frames = read_frames("stream-json-auth-failure.jsonl")
      assert length(frames) == 4

      result_frame = Enum.at(frames, 3)
      assert result_frame["type"] == "result"
      assert result_frame["subtype"] == "success"
      assert result_frame["is_error"] == true
      assert result_frame["terminal_reason"] == "api_error"

      events = normalize_all(frames)
      errors = Enum.filter(events, &(&1.kind == :error))
      assert length(errors) == 1

      [error] = errors
      assert error.error.category == :task_failed
      assert error.error.code == "api_error"
      refute error.error.category == :quota_refused
    end

    test "resume auth-failure capture normalizes the same way" do
      frames = read_frames("stream-json-resume-auth-failure.jsonl")
      assert length(frames) == 3

      events = normalize_all(frames)
      errors = Enum.filter(events, &(&1.kind == :error))
      assert length(errors) == 1
      assert hd(errors).error.category == :task_failed
    end
  end

  describe "robustness (adapter isolation)" do
    test "malformed and unknown frames skip, never raise" do
      assert {:skip, :unhandled_frame} =
               EventNormalizer.normalize(%{"corrupted" => true}, @run_id, 1, %{})

      assert {:skip, :unhandled_frame} = EventNormalizer.normalize(nil, @run_id, 1, %{})
      assert {:skip, :unhandled_frame} = EventNormalizer.normalize("not a map", @run_id, 1, %{})

      assert {:skip, :unhandled_frame} =
               EventNormalizer.normalize(%{"type" => "telepathy"}, @run_id, 1, %{})

      assert {:skip, _} =
               EventNormalizer.normalize(%{"type" => "assistant"}, @run_id, 1, %{})

      assert {:skip, _} =
               EventNormalizer.normalize(
                 %{
                   "type" => "assistant",
                   "message" => %{"content" => [%{"type" => "thinking", "text" => "hmm"}]}
                 },
                 @run_id,
                 1,
                 %{}
               )
    end

    test "secret patterns in tool commands are scrubbed" do
      frame = %{
        "type" => "assistant",
        "session_id" => "aaaaaaaa-0000-4000-a000-000000000002",
        "message" => %{
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "toolu_000000000000000000000099",
              "name" => "Bash",
              "input" => %{"command" => "deploy --api-key=supersecret123", "description" => "x"}
            }
          ]
        }
      }

      {:ok, [event]} = EventNormalizer.normalize(frame, @run_id, 1, %{})
      command = event.extensions["claude-headless:command"]
      assert command =~ "[REDACTED_SECRET]"
      refute command =~ "supersecret123"
    end

    test "sanitize_string is total" do
      assert EventNormalizer.sanitize_string(nil) == nil
      assert EventNormalizer.sanitize_string("/Users/someone/x") == "$HOME/x"
      assert is_binary(EventNormalizer.sanitize_string(123))
    end
  end

  describe "argv contract" do
    test "build_argv pins the evidence-backed shape" do
      alias Shoestring.Harness.ClaudeHeadless

      assert ClaudeHeadless.build_argv("Do it.") == [
               "claude",
               "--print",
               "--verbose",
               "--output-format",
               "stream-json",
               "--dangerously-skip-permissions",
               "--tools=Bash",
               "Do it."
             ]
    end
  end
end
