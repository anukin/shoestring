defmodule ShoestringWeb.TerminalBrowser do
  @moduledoc "Local browser identity used to bind terminal capabilities."
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, _opts) do
    if local?(conn.remote_ip) and not valid?(get_session(conn, "terminal_browser")),
      do: put_session(conn, "terminal_browser", :crypto.strong_rand_bytes(32)),
      else: conn
  end

  def local?({127, _, _, _}), do: true
  def local?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def local?(_address), do: false
  def valid?(value), do: is_binary(value) and byte_size(value) == 32
end
