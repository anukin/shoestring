defmodule ShoestringWeb.McpController do
  @moduledoc """
  `POST /mcp`: the coordinator's MCP tool endpoint (iteration 15, package B).

  Refused before any JSON-RPC is read unless the request comes from a
  loopback address, names a local host (no DNS rebinding), carries no Origin
  or a local one (no browser page on another site), and presents a bearer
  token `Shoestring.Coordinator.ToolTokens` knows. The token decides the
  session and repository every tool acts for.
  """

  use ShoestringWeb, :controller

  alias Shoestring.Coordinator.{Mcp, ToolTokens}

  @local_hosts ["localhost", "127.0.0.1", "::1", "[::1]"]

  def post(conn, _params) do
    with :ok <- local(conn),
         {:ok, binding} <- authorized(conn) do
      case Mcp.handle(message(conn), binding) do
        {:reply, response} -> json(conn, response)
        :accepted -> send_resp(conn, 202, "")
      end
    else
      {:error, status} -> refuse(conn, status)
    end
  end

  def not_allowed(conn, _params) do
    conn
    |> put_resp_header("allow", "POST")
    |> send_resp(405, "")
  end

  # Plug.Parsers puts a JSON body that is not an object under "_json".
  defp message(%{body_params: %{"_json" => other}}), do: other
  defp message(%{body_params: body}), do: body

  defp local(conn) do
    origin_ok =
      case get_req_header(conn, "origin") do
        [] -> true
        [origin] -> URI.parse(origin).host in @local_hosts
        _ -> false
      end

    if ShoestringWeb.TerminalBrowser.local?(conn.remote_ip) and conn.host in @local_hosts and
         origin_ok,
       do: :ok,
       else: {:error, 403}
  end

  defp authorized(conn) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, binding} <- ToolTokens.lookup(String.trim(token)) do
      {:ok, binding}
    else
      _ -> {:error, 401}
    end
  end

  defp refuse(conn, 401) do
    conn
    |> put_resp_header("www-authenticate", "Bearer")
    |> send_resp(401, "")
  end

  defp refuse(conn, status), do: send_resp(conn, status, "")
end
