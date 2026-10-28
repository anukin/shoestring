defmodule Shoestring.Harness.ConversationEvent do
  @moduledoc """
  One normalized event of a `Shoestring.Harness.Conversation`.

  Types and the fields each sets:

    * `:session` — `provider_session_id`, the id that resumes this session.
    * `:turn_started` — `turn_id`.
    * `:text` — `turn_id`, `text`: visible assistant text, never reasoning.
    * `:tool_call` — `turn_id`, `tool`, `tool_call_id`. The tool's input is
      not carried.
    * `:tool_result` — `turn_id`, `tool_call_id`, `is_error`. The result
      itself is not carried.
    * `:turn_completed` — `turn_id`, `status` (`:completed`, `:interrupted`
      or `:failed`), `usage` (token counts the harness reported, or `%{}`).
    * `:closed` — `reason`, and `turn_id` when a turn was still open; that
      turn's outcome is unknown.

  `ordinal` counts from 1 within one conversation process.
  """

  @types [:session, :turn_started, :text, :tool_call, :tool_result, :turn_completed, :closed]
  @statuses [:completed, :interrupted, :failed]

  defstruct [
    :type,
    :ordinal,
    :occurred_at,
    :turn_id,
    :provider_session_id,
    :text,
    :tool,
    :tool_call_id,
    :is_error,
    :status,
    :reason,
    usage: %{}
  ]

  @type type ::
          :session | :turn_started | :text | :tool_call | :tool_result | :turn_completed | :closed

  @type t :: %__MODULE__{
          type: type(),
          ordinal: pos_integer(),
          occurred_at: DateTime.t(),
          turn_id: String.t() | nil,
          provider_session_id: String.t() | nil,
          text: String.t() | nil,
          tool: String.t() | nil,
          tool_call_id: String.t() | nil,
          is_error: boolean() | nil,
          status: :completed | :interrupted | :failed | nil,
          reason: term(),
          usage: %{optional(String.t()) => non_neg_integer()}
        }

  @doc "The event types, in no particular order."
  def types, do: @types

  @doc "Builds an event, raising on an unknown type or turn status."
  @spec new(type(), pos_integer(), keyword()) :: t()
  def new(type, ordinal, fields \\ [])
      when type in @types and is_integer(ordinal) and ordinal > 0 do
    event =
      struct!(
        __MODULE__,
        [type: type, ordinal: ordinal, occurred_at: DateTime.utc_now()] ++ fields
      )

    if type == :turn_completed and event.status not in @statuses,
      do: raise(ArgumentError, "turn status must be one of #{inspect(@statuses)}")

    event
  end
end
