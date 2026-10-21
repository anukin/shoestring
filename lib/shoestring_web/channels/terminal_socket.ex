defmodule ShoestringWeb.TerminalSocket do
  @moduledoc "Loopback-only cookie/CSRF-bound terminal transport."
  use Phoenix.Socket
  channel "terminal:*", ShoestringWeb.TerminalChannel
  @impl true
  def connect(%{"token" => token}, socket, %{
        session: session,
        peer_data: %{address: address},
        uri: uri
      })
      when is_map(session) do
    browser = session["terminal_browser"]

    if ShoestringWeb.TerminalBrowser.local?(address) and
         uri.host in ["localhost", "127.0.0.1", "::1"] and
         ShoestringWeb.TerminalAccess.socket(token, browser) == :ok,
       do: {:ok, assign(socket, :terminal_browser, browser)},
       else: :error
  end

  def connect(_params, _socket, _info), do: :error
  @impl true
  def id(_socket), do: nil
end
