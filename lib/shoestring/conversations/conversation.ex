defmodule Shoestring.Conversations.Conversation do
  @moduledoc """
  A coordinator session's conversation. Its id is the goal whose trajectory
  holds the conversation's events (`Shoestring.Conversations.Events`); this
  row is how a session finds it, and the coordinator its turns run with.

  A handoff (`Shoestring.Conversations.Handoff`) continues the session in a
  new conversation: the old one gets `handed_off_at` and the new one names it
  as `predecessor_id`. A session has at most one conversation not handed off.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "coordinator_conversations" do
    field :session_id, :string
    field :provider, :string
    field :model, :string
    field :effort, :string
    field :repository_root, :string
    field :predecessor_id, :binary_id
    field :handed_off_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
