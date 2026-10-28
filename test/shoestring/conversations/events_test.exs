defmodule Shoestring.Conversations.EventsTest do
  use ExUnit.Case, async: true

  alias Shoestring.Trajectory.EventRegistry

  @turn "00000000-0000-4000-8000-000000000001"

  defp validate(type, payload), do: EventRegistry.validate_payload(type, 1, payload)

  test "a turn ends with a known outcome and integer usage only" do
    assert {:ok, _} =
             validate("conversation.turn.ended", %{
               "turn_id" => @turn,
               "status" => "uncertain",
               "reason" => "service_restarted",
               "usage" => %{"output_tokens" => 7}
             })

    assert {:error, _} =
             validate("conversation.turn.ended", %{"turn_id" => @turn, "status" => "retried"})

    assert {:error, _} =
             validate("conversation.turn.ended", %{
               "turn_id" => @turn,
               "status" => "completed",
               "usage" => %{"output_tokens" => "7"}
             })
  end

  test "a turn delivers something, and an inbox entry names a settled state" do
    assert {:error, _} =
             validate("conversation.turn.requested", %{
               "turn_id" => @turn,
               "message_ids" => [],
               "inbox_ids" => []
             })

    assert {:ok, _} =
             validate("conversation.inbox.recorded", %{
               "entry_id" => @turn,
               "dispatch_id" => @turn,
               "state" => "needs_you"
             })

    assert {:error, _} =
             validate("conversation.inbox.recorded", %{
               "entry_id" => @turn,
               "dispatch_id" => @turn,
               "state" => "running"
             })
  end

  test "a turn's admission is only its decision id, result and reason; a hold names a reason" do
    turn = %{"turn_id" => @turn, "message_ids" => [@turn], "inbox_ids" => [], "grant_id" => @turn}

    assert {:ok, _} =
             validate(
               "conversation.turn.requested",
               Map.put(turn, "admission", %{
                 "decision_id" => @turn,
                 "result" => "admit",
                 "reason_code" => "confirmed_unknown_capacity"
               })
             )

    assert {:error, _} =
             validate(
               "conversation.turn.requested",
               Map.put(turn, "admission", %{
                 "decision_id" => @turn,
                 "result" => "admit",
                 "reason_code" => "confirmed_unknown_capacity",
                 "explanation" => "free text"
               })
             )

    assert {:ok, _} = validate("conversation.turn.held", %{"reason" => "turns_exhausted"})
    assert {:error, _} = validate("conversation.turn.held", %{"reason" => "no reason given"})
  end

  test "tool events carry a call id and tool name, never the tool's input" do
    assert {:ok, _} =
             validate("conversation.tool.called", %{
               "turn_id" => @turn,
               "call_id" => "toolu_01",
               "tool" => "mcp__shoestring__dispatch"
             })

    assert {:error, _} =
             validate("conversation.tool.called", %{
               "turn_id" => @turn,
               "call_id" => "toolu_01",
               "tool" => "dispatch",
               "input" => %{"brief" => "..."}
             })
  end
end
