defmodule Shoestring.Conversations.Events do
  @moduledoc """
  Canonical conversation facts (iteration 15 package C): visible messages,
  turns, tool names and inbox entries. Never hidden reasoning, tool inputs or
  raw provider frames.
  """

  alias Shoestring.Harness.Contract

  # `uncertain`: the turn may have reached the model but its end was never
  # seen (the service or the coordinator process stopped first). `unsent`:
  # it was recorded but never handed to the coordinator.
  @statuses ~w(completed interrupted failed uncertain unsent)
  @inbox_states ~w(waiting held needs_you completed cancelled failed failed_to_start)
  @name ~r/\A[A-Za-z0-9_.:-]{1,200}\z/

  def statuses, do: @statuses
  def inbox_states, do: @inbox_states

  def validate("conversation.turn.ended", payload) do
    if payload["status"] in @statuses and usage?(payload["usage"]),
      do: :ok,
      else: Contract.invalid(:status, "must be a turn outcome with integer usage counts")
  end

  def validate("conversation.turn.requested", payload) do
    if payload["message_ids"] != [] or payload["inbox_ids"] != [],
      do: :ok,
      else: Contract.invalid(:message_ids, "a turn delivers at least one message or entry")
  end

  def validate("conversation.message.coordinator", payload) do
    if payload["item"] >= 0,
      do: :ok,
      else: Contract.invalid(:item, "must not be negative")
  end

  def validate(type, payload)
      when type in ["conversation.tool.called", "conversation.tool.returned"] do
    if name?(payload["call_id"]) and
         (type == "conversation.tool.returned" or name?(payload["tool"])),
       do: :ok,
       else: Contract.invalid(:call_id, "must be a tool call id and tool name")
  end

  def validate("conversation.inbox.recorded", payload) do
    if payload["state"] in @inbox_states,
      do: :ok,
      else: Contract.invalid(:state, "must be a settled dispatch state")
  end

  def validate(_type, _payload), do: :ok

  defp name?(value), do: is_binary(value) and Regex.match?(@name, value)

  defp usage?(nil), do: true

  defp usage?(usage) when is_map(usage),
    do: Enum.all?(usage, fn {key, value} -> name?(key) and is_integer(value) end)

  defp usage?(_usage), do: false
end
