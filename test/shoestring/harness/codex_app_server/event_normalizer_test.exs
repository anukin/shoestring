defmodule Shoestring.Harness.CodexAppServer.EventNormalizerTest do
  use ExUnit.Case, async: true

  alias Shoestring.Harness.{Error, HarnessEvent}
  alias Shoestring.Harness.CodexAppServer.EventNormalizer

  @run_id "00000000-0000-4000-8000-000000000001"
  @session_id "01950000-0000-7000-8000-000000000001"
  @turn_id "01950000-0000-7000-8000-000000000003"
  @fixtures_dir Path.expand("../../../fixtures/codex/app_server", __DIR__)

  defp load_fixture!(name) do
    path = Path.join(@fixtures_dir, name)
    path |> File.read!() |> Jason.decode!()
  end

  describe "committed fixture-driven frame normalization" do
    test "normalizes thread/start and workspace write proof frames" do
      fixture = load_fixture!("thread-start-workspace-write.json")

      # Test file change completed item
      item = fixture["file_change_completed_item"]
      frame = %{"method" => "item/completed", "params" => %{"item" => item}}

      assert {:ok, %HarnessEvent{} = event} =
               EventNormalizer.normalize(frame, @run_id, 1, %{provider_session_id: @session_id})

      assert event.kind == :tool
      assert event.run_id == @run_id
      assert event.extensions["codex-app-server:tool"] == "fileChange"
      assert event.extensions["codex-app-server:status"] == "completed"
      assert is_list(event.extensions["codex-app-server:changes"])

      # Test completed turn
      turn = fixture["turn_completed"]
      turn_frame = %{"method" => "turn/completed", "params" => %{"turn" => turn}}

      assert {:ok, %HarnessEvent{} = turn_event} =
               EventNormalizer.normalize(turn_frame, @run_id, 2, %{
                 provider_session_id: @session_id
               })

      assert turn_event.kind == :result
      assert turn_event.result.status == "completed"
      assert turn_event.extensions["codex-app-server:status"] == "completed"
    end

    test "normalizes turn-interrupt frames and bracketing status frames" do
      fixture = load_fixture!("turn-interrupt.json")

      # Command item started (inProgress)
      cmd_item = fixture["command_item_started"]
      frame = %{"method" => "item/started", "params" => %{"item" => cmd_item}}

      assert {:ok, %HarnessEvent{} = event} =
               EventNormalizer.normalize(frame, @run_id, 1, %{provider_session_id: @session_id})

      assert event.kind == :command
      assert event.process_id == "43138"
      assert event.extensions["codex-app-server:command"] == "/bin/zsh -lc 'sleep 45'"
      assert event.extensions["codex-app-server:status"] == "inProgress"

      # Turn completed with status: interrupted
      turn = fixture["turn_completed_frame"]
      turn_frame = %{"method" => "turn/completed", "params" => %{"turn" => turn}}

      assert {:ok, %HarnessEvent{} = turn_event} =
               EventNormalizer.normalize(turn_frame, @run_id, 2, %{
                 provider_session_id: @session_id
               })

      assert turn_event.kind == :result
      assert turn_event.result.status == "interrupted"
      assert turn_event.extensions["codex-app-server:interrupted"] == true
      assert turn_event.extensions["codex-app-server:status"] == "interrupted"

      # Bracketing frames
      for bf <- fixture["bracketing_frames"] do
        assert {:ok, %HarnessEvent{} = bf_event} =
                 EventNormalizer.normalize(bf, @run_id, 3, %{provider_session_id: @session_id})

        assert bf_event.kind == :lifecycle
      end
    end

    test "normalizes verified commandExecution completed shape and resume frame" do
      fixture = load_fixture!("thread-resume-and-command-complete.json")

      # Command execution completed item
      cmd_item = fixture["command_execution_completed_item"]
      frame = %{"method" => "item/completed", "params" => %{"item" => cmd_item}}

      assert {:ok, %HarnessEvent{} = event} =
               EventNormalizer.normalize(frame, @run_id, 1, %{provider_session_id: @session_id})

      assert event.kind == :command
      assert event.process_id == "29968"
      assert event.extensions["codex-app-server:status"] == "completed"
      assert event.extensions["codex-app-server:exit_code"] == 0
      assert event.extensions["codex-app-server:command"] =~ "printf hello_live"
      assert is_integer(event.extensions["codex-app-server:duration_ms"])
    end

    test "normalizes rateLimits/updated mid-turn frame" do
      fixture = load_fixture!("rate-limits-mid-turn.json")
      frame = fixture["frame"]

      assert {:ok, %HarnessEvent{} = event} =
               EventNormalizer.normalize(frame, @run_id, 1, %{provider_session_id: @session_id})

      assert event.kind == :lifecycle
      assert event.extensions["codex-app-server:method"] == "account/rateLimits/updated"
    end
  end

  describe "secret scrubbing and hidden reasoning elimination" do
    test "completely drops thinking, reasoning, and thought items" do
      for bad_type <- ["reasoning", "thought", "thinking"] do
        started_frame = %{
          "method" => "item/started",
          "params" => %{
            "item" => %{"type" => bad_type, "id" => "secret_1", "text" => "hidden thought"}
          }
        }

        completed_frame = %{
          "method" => "item/completed",
          "params" => %{
            "item" => %{"type" => bad_type, "id" => "secret_1", "text" => "hidden thought"}
          }
        }

        assert {:skip, :hidden_reasoning} =
                 EventNormalizer.normalize(started_frame, @run_id, 1, %{})

        assert {:skip, :hidden_reasoning} =
                 EventNormalizer.normalize(completed_frame, @run_id, 1, %{})
      end
    end

    test "sanitizes Bearer tokens, OpenAI API keys, and /Users/ paths in output" do
      frame = %{
        "method" => "item/completed",
        "params" => %{
          "item" => %{
            "type" => "agentMessage",
            "id" => "msg_1",
            "text" =>
              "Look at /Users/john_doe/secret.txt with Bearer eyJhbGciOiJIUz and sk-proj-1234567890abcdef"
          }
        }
      }

      assert {:ok, %HarnessEvent{} = event} =
               EventNormalizer.normalize(frame, @run_id, 1, %{provider_session_id: @session_id})

      sanitized_text = event.extensions["codex-app-server:text"]
      refute sanitized_text =~ "/Users/john_doe"
      assert sanitized_text =~ "$HOME/secret.txt"
      refute sanitized_text =~ "eyJhbGci"
      assert sanitized_text =~ "[REDACTED_BEARER]"
      refute sanitized_text =~ "sk-proj-"
      assert sanitized_text =~ "[REDACTED_KEY]"
    end
  end

  describe "quota refusal and error classification" do
    test "maps usageLimitExceeded and rateLimitExceeded to :quota_refused" do
      for refusal_code <- ["usageLimitExceeded", "rateLimitExceeded"] do
        turn_error = %{
          "message" => "Quota exceeded",
          "codexErrorInfo" => refusal_code
        }

        turn_frame = %{
          "method" => "turn/completed",
          "params" => %{
            "turn" => %{
              "id" => @turn_id,
              "status" => "failed",
              "error" => turn_error
            }
          }
        }

        assert {:ok, %HarnessEvent{} = event} =
                 EventNormalizer.normalize(turn_frame, @run_id, 1, %{})

        assert event.kind == :error
        assert %Error{} = err = event.error
        assert err.category == :quota_refused
        assert err.code == refusal_code
        assert err.message =~ "Quota exceeded"
      end
    end

    test "maps unauthorized to :authentication_required" do
      turn_error = %{
        "message" => "Authentication failed",
        "codexErrorInfo" => "unauthorized"
      }

      err = EventNormalizer.normalize_codex_error(turn_error)
      assert err.category == :authentication_required
      assert err.code == "unauthorized"
    end

    test "maps serverOverloaded to :transport" do
      turn_error = %{
        "message" => "Codex server is overloaded",
        "codexErrorInfo" => "serverOverloaded"
      }

      err = EventNormalizer.normalize_codex_error(turn_error)
      assert err.category == :transport
      assert err.code == "serverOverloaded"
    end

    test "maps generic errors to :task_failed" do
      turn_error = %{
        "message" => "Syntax error in script",
        "codexErrorInfo" => "badRequest"
      }

      err = EventNormalizer.normalize_codex_error(turn_error)
      assert err.category == :task_failed
      assert err.code == "badRequest"
    end
  end

  describe "graceful fallback for missing tool/command fields" do
    test "handles commandExecution item with null exitCode and aggregatedOutput" do
      item = %{
        "type" => "commandExecution",
        "id" => "exec-1",
        "command" => "sleep 10",
        "cwd" => "/tmp",
        "status" => "completed",
        "exitCode" => nil,
        "aggregatedOutput" => nil
      }

      frame = %{"method" => "item/completed", "params" => %{"item" => item}}

      assert {:ok, %HarnessEvent{} = event} =
               EventNormalizer.normalize(frame, @run_id, 1, %{provider_session_id: @session_id})

      assert event.kind == :command
      assert event.extensions["codex-app-server:status"] == "completed"
      assert event.extensions["codex-app-server:command"] == "sleep 10"
      refute Map.has_key?(event.extensions, "codex-app-server:exit_code")
    end
  end
end
