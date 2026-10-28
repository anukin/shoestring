defmodule Shoestring.Coordinator.ToolTokensTest do
  use ExUnit.Case, async: true

  alias Shoestring.Coordinator.ToolTokens

  @binding %{session_id: "s-tokens", repository: "/repo"}

  test "a token resolves to its binding until it is revoked" do
    token = ToolTokens.issue(Map.put(@binding, :extra, "dropped"))
    assert byte_size(token) >= 43
    assert {:ok, @binding} = ToolTokens.lookup(token)

    assert :ok = ToolTokens.revoke(token)
    assert :error = ToolTokens.lookup(token)
    assert :ok = ToolTokens.revoke(token)
  end

  test "tokens are unique, and unknown or malformed ones resolve to nothing" do
    refute ToolTokens.issue(@binding) == ToolTokens.issue(@binding)
    assert :error = ToolTokens.lookup("not-a-token")
    assert :error = ToolTokens.lookup("")
    assert :error = ToolTokens.lookup(nil)
  end

  test "the registry keeps only a hash of each token" do
    token = ToolTokens.issue(@binding)
    stored = :ets.tab2list(ToolTokens)
    refute inspect(stored, limit: :infinity) =~ token
  end

  test "a token is revoked when the process that asked for it exits" do
    test = self()

    owner =
      spawn(fn ->
        send(test, {:token, ToolTokens.issue(@binding)})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:token, token}
    assert {:ok, _} = ToolTokens.lookup(token)

    ref = Process.monitor(owner)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^owner, _}
    # The registry handles the owner's DOWN before this call.
    _ = :sys.get_state(ToolTokens)
    assert :error = ToolTokens.lookup(token)
  end
end
