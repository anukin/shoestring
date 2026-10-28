defmodule ShoestringWeb.ChatSocket do
  @moduledoc """
  `/chat/socket`: the native chat client's transport (`docs/chat-channel.md`).
  Loopback peers naming a local host only (the endpoint refuses a non-local
  `Origin`), each presenting its conversation's token file
  (`Shoestring.Conversations.ChatToken`).
  """
  use Phoenix.Socket

  alias Shoestring.Conversations.ChatToken

  channel "conversation:*", ShoestringWeb.ChatChannel

  @local_hosts ["localhost", "127.0.0.1", "::1", "[::1]"]

  @impl true
  def connect(%{"session" => session, "token" => token}, socket, %{
        peer_data: %{address: address},
        uri: %URI{host: host}
      }) do
    if ShoestringWeb.TerminalBrowser.local?(address) and host in @local_hosts and
         ChatToken.verify(session, token) == :ok,
       do: {:ok, assign(socket, :session_id, session)},
       else: :error
  end

  def connect(_params, _socket, _info), do: :error

  @impl true
  def id(_socket), do: nil
end
