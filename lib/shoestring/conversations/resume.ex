defmodule Shoestring.Conversations.Resume do
  @moduledoc """
  At boot, starts the engine of each conversation whose session still has an
  active grant (`docs/chat-channel.md`). Starting an engine rebuilds its
  history and makes no model call.
  """
  use Task, restart: :temporary

  require Logger

  alias Shoestring.{Conversations, Grants, Repo}
  alias Shoestring.Conversations.Conversation

  def start_link(_arg), do: Task.start_link(&run/0)

  @doc "Starts the engines; returns the conversations started."
  def run(opts \\ Application.get_env(:shoestring, :conversation_engine_opts, [])) do
    for conversation <- Repo.all(Conversation),
        Grants.active(conversation.session_id),
        started?(conversation, opts),
        do: conversation
  end

  defp started?(conversation, opts) do
    case Conversations.start(conversation, opts) do
      {:ok, _pid} ->
        true

      {:error, reason} ->
        Logger.error(
          "conversation #{conversation.session_id} not resumed: #{inspect(reason, limit: 8)}"
        )

        false
    end
  end
end
