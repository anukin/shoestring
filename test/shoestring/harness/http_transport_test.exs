defmodule Shoestring.Harness.HTTPTransportTest do
  use ExUnit.Case, async: true
  alias Shoestring.Harness.HTTP.Transport

  test "Req transport bounds success and error bodies and never follows redirects" do
    for status <- [200, 400, 429] do
      plug = fn conn -> Plug.Conn.send_resp(conn, status, String.duplicate("x", 65_537)) end

      assert {:error, :http_response_oversized} =
               Transport.request(:post, "https://fixture.invalid/response", %{}, [], %{plug: plug})
    end

    plug = fn conn -> Plug.Conn.send_resp(conn, 200, ~s({"visible":"retained"})) end

    assert {:ok, 200, %{"visible" => "retained"}} =
             Transport.request(:post, "https://fixture.invalid/response", %{}, [], %{plug: plug})

    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://elsewhere.invalid/")
      |> Plug.Conn.send_resp(302, "{}")
    end

    assert {:ok, 302, %{}} =
             Transport.request(:get, "https://fixture.invalid/response", nil, [], %{plug: plug})
  end
end
