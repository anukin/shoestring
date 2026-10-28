defmodule Shoestring.Coordinator.McpTest do
  use ExUnit.Case, async: true

  alias Shoestring.Coordinator.{Mcp, Tools}

  @binding %{session_id: "s-mcp", repository: "/repo"}

  defp rpc(method, params \\ %{}, id \\ 1),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

  test "initialize echoes a served protocol version and offers tools only" do
    for version <- Mcp.versions() do
      assert {:reply, %{"id" => 1, "result" => result}} =
               Mcp.handle(rpc("initialize", %{"protocolVersion" => version}), @binding)

      assert result["protocolVersion"] == version
      assert result["capabilities"] == %{"tools" => %{"listChanged" => false}}
      assert result["serverInfo"]["name"] == "shoestring"
    end

    assert {:reply, %{"result" => %{"protocolVersion" => newest}}} =
             Mcp.handle(rpc("initialize", %{"protocolVersion" => "1999-01-01"}), @binding)

    assert newest == hd(Mcp.versions())
  end

  test "notifications and client responses get no reply" do
    assert :accepted =
             Mcp.handle(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}, @binding)

    assert :accepted = Mcp.handle(%{"jsonrpc" => "2.0", "id" => 3, "result" => %{}}, @binding)
  end

  test "unknown methods, including Claude's server/discover, are not found" do
    for method <- ["server/discover", "resources/list"] do
      assert {:reply, %{"id" => 7, "error" => %{"code" => -32_601}}} =
               Mcp.handle(rpc(method, %{}, 7), @binding)
    end
  end

  test "malformed messages are invalid requests" do
    for message <- [
          [],
          "text",
          %{"jsonrpc" => "1.0", "id" => 1, "method" => "ping"},
          %{"id" => 1}
        ] do
      assert {:reply, %{"id" => nil, "error" => %{"code" => -32_600}}} =
               Mcp.handle(message, @binding)
    end
  end

  test "ping answers and tools/list lists the coordinator tools" do
    assert {:reply, %{"result" => %{}}} = Mcp.handle(rpc("ping"), @binding)
    assert {:reply, %{"result" => %{"tools" => tools}}} = Mcp.handle(rpc("tools/list"), @binding)

    assert Enum.map(tools, & &1["name"]) ==
             ~w(dispatch runs_list runs_show runs_log runs_cancel capacity advice)

    assert tools == Tools.list()
    assert Enum.all?(tools, &(&1["inputSchema"]["type"] == "object"))
  end

  test "a tool's refusal or failure is a failed call, not a protocol error" do
    assert {:reply,
            %{"result" => %{"isError" => true, "content" => [%{"text" => "Unknown tool: nope"}]}}} =
             Mcp.handle(rpc("tools/call", %{"name" => "nope"}), @binding)

    assert {:reply,
            %{
              "result" => %{
                "isError" => true,
                "content" => [%{"text" => "dispatch needs `purpose`"}]
              }
            }} =
             Mcp.handle(rpc("tools/call", %{"name" => "dispatch", "arguments" => %{}}), @binding)

    # A binding without a session makes the tool raise; that is reported, not crashed.
    assert {:reply, %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}}} =
             Mcp.handle(rpc("tools/call", %{"name" => "runs_list"}), %{})

    assert text =~ "failed inside Shoestring"

    assert {:reply, %{"error" => %{"code" => -32_602}}} =
             Mcp.handle(rpc("tools/call", %{"name" => "runs_list", "arguments" => []}), @binding)

    assert {:reply, %{"error" => %{"code" => -32_602}}} =
             Mcp.handle(rpc("tools/call", %{}), @binding)
  end
end
