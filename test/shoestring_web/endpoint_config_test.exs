defmodule ShoestringWeb.EndpointConfigTest do
  use ExUnit.Case, async: false

  @loopback {127, 0, 0, 1}

  test "development, test, and production defaults bind to loopback" do
    assert endpoint_ip(Config.Reader.read!("config/dev.exs")) == @loopback
    assert endpoint_ip(Config.Reader.read!("config/test.exs")) == @loopback

    with_env("SECRET_KEY_BASE", String.duplicate("x", 64), fn ->
      assert endpoint_ip(Config.Reader.read!("config/runtime.exs", env: :prod)) == @loopback
    end)
  end

  test "production binding changes only with the explicit SHOESTRING_BIND override" do
    with_env("SECRET_KEY_BASE", String.duplicate("x", 64), fn ->
      with_env("SHOESTRING_BIND", "127.0.0.2", fn ->
        assert endpoint_ip(Config.Reader.read!("config/runtime.exs", env: :prod)) ==
                 {127, 0, 0, 2}
      end)
    end)
  end

  test "production LiveView accepts the supported local origins and rejects foreign origins" do
    with_env("PORT", "4018", fn ->
      with_env("PHX_HOST", "localhost", fn ->
        config = Config.Reader.read!("config/runtime.exs", env: :prod)
        endpoint = config |> Keyword.fetch!(:shoestring) |> Keyword.fetch!(ShoestringWeb.Endpoint)
        opts = Keyword.take(endpoint, [:check_origin])

        for origin <- ["http://localhost:4018", "http://127.0.0.1:4018", "http://[::1]:4018"] do
          refute origin_check(origin, opts).halted, origin
        end

        for origin <- [
              "https://example.invalid:4018",
              "http://localhost.example.invalid:4018",
              "http://127.0.0.1:4019",
              "https://localhost:4018"
            ] do
          conn = origin_check(origin, opts)
          assert conn.halted, origin
          assert conn.status == 403
        end
      end)
    end)
  end

  defp origin_check(origin, opts) do
    :get
    |> Plug.Test.conn("http://127.0.0.1:4018/live/websocket")
    |> Plug.Conn.put_req_header("origin", origin)
    |> Phoenix.Socket.Transport.check_origin(
      Phoenix.LiveView.Socket,
      ShoestringWeb.Endpoint,
      opts
    )
  end

  defp endpoint_ip(config) do
    config
    |> Keyword.fetch!(:shoestring)
    |> Enum.find_value(fn
      {ShoestringWeb.Endpoint, endpoint_config} -> get_in(endpoint_config, [:http, :ip])
      _other -> nil
    end)
  end

  defp with_env(name, value, fun) do
    previous = System.get_env(name)
    System.put_env(name, value)

    try do
      fun.()
    after
      restore_env(name, previous)
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
