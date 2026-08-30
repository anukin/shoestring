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
