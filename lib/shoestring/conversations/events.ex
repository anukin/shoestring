defmodule Shoestring.Conversations.Events do
  @moduledoc """
  Canonical conversation facts (iteration 15 package C): visible messages,
  turns, tool names and inbox entries. Never hidden reasoning, tool inputs or
  raw provider frames.
  """

  alias Shoestring.Conversations.Handoff
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
    cond do
      payload["message_ids"] == [] and payload["inbox_ids"] == [] ->
        Contract.invalid(:message_ids, "a turn delivers at least one message or entry")

      not admission?(payload["admission"]) ->
        Contract.invalid(:admission, "must be an admission decision's id, result and reason")

      true ->
        :ok
    end
  end

  def validate("conversation.turn.held", payload) do
    if name?(payload["reason"]),
      do: :ok,
      else: Contract.invalid(:reason, "must be a reason code")
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

  def validate(type, payload)
      when type in ["conversation.handoff.prepared", "conversation.handoff.received"] do
    cond do
      not name?(payload["note_status"]) ->
        Contract.invalid(:note_status, "must be a note status code")

      is_binary(payload["note"]) and byte_size(payload["note"]) > Handoff.max_note_bytes() ->
        Contract.invalid(:note, "must be at most #{Handoff.max_note_bytes()} bytes")

      true ->
        :ok
    end
  end

  def validate(_type, _payload), do: :ok

  defp name?(value), do: is_binary(value) and Regex.match?(@name, value)

  defp admission?(nil), do: true

  defp admission?(admission) when is_map(admission),
    do:
      Enum.sort(Map.keys(admission)) == ~w(decision_id reason_code result) and
        Enum.all?(Map.values(admission), &name?/1)

  defp admission?(_admission), do: false

  defp usage?(nil), do: true

  defp usage?(usage) when is_map(usage),
    do: Enum.all?(usage, fn {key, value} -> name?(key) and is_integer(value) end)

  defp usage?(_usage), do: false
end
