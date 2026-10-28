defmodule Shoestring.Harness.ClaudeHeadless.ConversationFrames do
  @moduledoc """
  Classifies one Claude Code stream-json frame of a coordinator conversation
  (`claude -p --input-format stream-json --output-format stream-json`).

  Only what a conversation forwards is read: the session id, visible text,
  tool names and ids, tool error flags, the turn's result and token usage,
  and control responses. Reasoning blocks, tool inputs, tool results and
  every other member are dropped here, so they never reach an event.

  Frame shapes observed with Claude Code 2.1.312 against a scripted model
  (`plans/evidence/15-native-chat/`): a `system`/`init` frame starts every
  turn; each `assistant` frame carries content blocks; tool results come
  back in `user` frames; one `result` frame ends each turn; an interrupted
  turn ends with `result`/`error_during_execution`.
  """

  @usage_keys ~w(input_tokens output_tokens cache_read_input_tokens cache_creation_input_tokens)

  @type item ::
          {:text, String.t()}
          | {:tool_call, String.t(), String.t()}
          | {:tool_result, String.t(), boolean()}

  @type t ::
          {:init, String.t()}
          | {:items, [item()]}
          | {:result, %{success: boolean(), subtype: String.t() | nil, usage: map()}}
          | {:control_response, String.t(), map()}
          | :ignore

  @doc "Classifies a decoded frame."
  @spec classify(map()) :: t()
  def classify(%{"type" => "system", "subtype" => "init", "session_id" => id}) when is_binary(id),
    do: {:init, id}

  def classify(%{"type" => "assistant", "message" => %{"content" => blocks}})
      when is_list(blocks),
      do: {:items, Enum.flat_map(blocks, &assistant_block/1)}

  def classify(%{"type" => "user", "message" => %{"content" => blocks}}) when is_list(blocks),
    do: {:items, Enum.flat_map(blocks, &user_block/1)}

  def classify(%{"type" => "result"} = frame) do
    {:result,
     %{
       success: frame["subtype"] == "success" and frame["is_error"] != true,
       subtype: string(frame["subtype"]),
       usage: usage(frame["usage"])
     }}
  end

  def classify(%{"type" => "control_response", "response" => %{"request_id" => id} = response})
      when is_binary(id),
      do: {:control_response, id, response}

  def classify(_frame), do: :ignore

  defp assistant_block(%{"type" => "text", "text" => text}) when is_binary(text) and text != "",
    do: [{:text, text}]

  defp assistant_block(%{"type" => "tool_use", "id" => id, "name" => name})
       when is_binary(id) and is_binary(name),
       do: [{:tool_call, name, id}]

  defp assistant_block(_block), do: []

  defp user_block(%{"type" => "tool_result", "tool_use_id" => id} = block) when is_binary(id),
    do: [{:tool_result, id, block["is_error"] == true}]

  defp user_block(_block), do: []

  defp usage(%{} = usage) do
    for key <- @usage_keys,
        value = usage[key],
        is_integer(value) and value >= 0,
        into: %{},
        do: {key, value}
  end

  defp usage(_usage), do: %{}

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil
end
