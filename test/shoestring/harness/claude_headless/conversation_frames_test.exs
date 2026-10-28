defmodule Shoestring.Harness.ClaudeHeadless.ConversationFramesTest do
  use ExUnit.Case, async: true

  alias Shoestring.Harness.ClaudeHeadless.ConversationFrames

  test "init carries the session id" do
    assert {:init, "sid"} =
             ConversationFrames.classify(%{
               "type" => "system",
               "subtype" => "init",
               "session_id" => "sid"
             })
  end

  test "assistant text and tool calls keep what is visible and drop reasoning and inputs" do
    frame = %{
      "type" => "assistant",
      "message" => %{
        "content" => [
          %{"type" => "thinking", "thinking" => "hidden", "signature" => "s"},
          %{"type" => "redacted_thinking", "data" => "opaque"},
          %{"type" => "text", "text" => "visible"},
          %{"type" => "text", "text" => ""},
          %{
            "type" => "tool_use",
            "id" => "toolu_1",
            "name" => "Read",
            "input" => %{"file_path" => "/x"}
          }
        ]
      }
    }

    assert {:items, [{:text, "visible"}, {:tool_call, "Read", "toolu_1"}]} =
             ConversationFrames.classify(frame)
  end

  test "tool results keep only the id and the error flag" do
    frame = %{
      "type" => "user",
      "message" => %{
        "content" => [
          %{
            "type" => "tool_result",
            "tool_use_id" => "toolu_1",
            "content" => "file text",
            "is_error" => true
          },
          %{
            "type" => "tool_result",
            "tool_use_id" => "toolu_2",
            "content" => [%{"type" => "text", "text" => "ok"}]
          },
          %{"type" => "text", "text" => "a user message echo"}
        ]
      }
    }

    assert {:items, [{:tool_result, "toolu_1", true}, {:tool_result, "toolu_2", false}]} =
             ConversationFrames.classify(frame)
  end

  test "results report success, the subtype and only well-formed token counts" do
    assert {:result, %{success: true, subtype: "success", usage: usage}} =
             ConversationFrames.classify(%{
               "type" => "result",
               "subtype" => "success",
               "is_error" => false,
               "result" => "final text is not repeated",
               "usage" => %{
                 "input_tokens" => 5,
                 "output_tokens" => 2,
                 "cache_read_input_tokens" => -1,
                 "cache_creation_input_tokens" => "3",
                 "server_tool_use" => %{"web_search_requests" => 0}
               }
             })

    assert usage == %{"input_tokens" => 5, "output_tokens" => 2}

    assert {:result, %{success: false, subtype: "error_during_execution", usage: %{}}} =
             ConversationFrames.classify(%{
               "type" => "result",
               "subtype" => "error_during_execution",
               "is_error" => true
             })

    assert {:result, %{success: false}} =
             ConversationFrames.classify(%{
               "type" => "result",
               "subtype" => "success",
               "is_error" => true
             })
  end

  test "control responses are matched by request id; everything else is ignored" do
    assert {:control_response, "initialize", %{"subtype" => "success"}} =
             ConversationFrames.classify(%{
               "type" => "control_response",
               "response" => %{"subtype" => "success", "request_id" => "initialize"}
             })

    for frame <- [
          %{"type" => "rate_limit_event"},
          %{"type" => "system", "subtype" => "ui_invalidate"},
          %{"type" => "stream_event"},
          %{"no" => "type"}
        ],
        do: assert(ConversationFrames.classify(frame) == :ignore)
  end
end
