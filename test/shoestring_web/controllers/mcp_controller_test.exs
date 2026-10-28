defmodule ShoestringWeb.McpControllerTest do
  use ShoestringWeb.ConnCase, async: true

  alias Shoestring.Coordinator.ToolTokens

  setup %{conn: conn} do
    token = ToolTokens.issue(%{session_id: "s-http", repository: "/repo"})
    %{conn: %{conn | host: "localhost"}, token: token}
  end

  defp post_rpc(conn, token, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> then(&if(token, do: put_req_header(&1, "authorization", "Bearer " <> token), else: &1))
    |> post("/mcp", Jason.encode!(body))
  end

  @initialize %{
    "jsonrpc" => "2.0",
    "id" => 1,
    "method" => "initialize",
    "params" => %{"protocolVersion" => "2025-06-18"}
  }

  test "a local request with its token is served", %{conn: conn, token: token} do
    conn = post_rpc(conn, token, @initialize)

    assert %{"id" => 1, "result" => %{"protocolVersion" => "2025-06-18"}} =
             json_response(conn, 200)
  end

  test "a notification is accepted with no body", %{conn: conn, token: token} do
    conn = post_rpc(conn, token, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    assert response(conn, 202) == ""
  end

  test "a request without a known token is unauthorized", %{conn: conn} do
    for token <- [nil, "wrong"] do
      conn = post_rpc(conn, token, @initialize)
      assert response(conn, 401) == ""
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    end
  end

  test "a revoked token is unauthorized", %{conn: conn, token: token} do
    :ok = ToolTokens.revoke(token)
    assert response(post_rpc(conn, token, @initialize), 401) == ""
  end

  test "requests that are not local are forbidden, even with the token", %{
    conn: conn,
    token: token
  } do
    remote = %{conn | remote_ip: {192, 168, 1, 20}}
    assert response(post_rpc(remote, token, @initialize), 403) == ""

    rebound = %{conn | host: "evil.example"}
    assert response(post_rpc(rebound, token, @initialize), 403) == ""

    foreign = put_req_header(conn, "origin", "https://evil.example")
    assert response(post_rpc(foreign, token, @initialize), 403) == ""

    local_origin = put_req_header(conn, "origin", "http://localhost:4000")
    assert json_response(post_rpc(local_origin, token, @initialize), 200)
  end

  test "a body that is not a JSON-RPC object is an invalid request", %{conn: conn, token: token} do
    conn = post_rpc(conn, token, [@initialize])
    assert %{"error" => %{"code" => -32_600}} = json_response(conn, 200)
  end

  test "GET and DELETE are not served, even when an event stream is asked for", %{conn: conn} do
    # MCP clients probe GET with this Accept; 405 tells them no stream is offered.
    conn = put_req_header(conn, "accept", "text/event-stream")

    for method <- [:get, :delete] do
      conn = dispatch(conn, @endpoint, method, "/mcp")
      assert response(conn, 405) == ""
      assert get_resp_header(conn, "allow") == ["POST"]
    end
  end
end
