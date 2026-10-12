defmodule Shoestring.Harness.Capacity.Codex.StdioTransportGroupTest do
  use ExUnit.Case, async: true

  alias Shoestring.Harness.Capacity.Codex.StdioTransport

  test "production stdio port is a group leader and preserves JSON-RPC stdin" do
    python = System.find_executable("python3")
    assert python

    script = """
    import json, os, sys
    print(json.dumps({"pid": os.getpid(), "pgid": os.getpgid(0)}), flush=True)
    for line in sys.stdin:
        print(line, end="", flush=True)
    """

    transport =
      start_supervised!(
        {StdioTransport, owner: self(), executable: python, args: ["-u", "-c", script]}
      )

    assert_receive {:codex_transport_connected, ^transport}
    assert_receive {:codex_transport_frame, ^transport, identity}, 5_000
    identity = Jason.decode!(identity)
    assert StdioTransport.os_pid(transport) == identity["pid"]

    frame = %{"id" => 1, "method" => "fixture/echo", "params" => %{"required" => "retained"}}
    assert :ok = StdioTransport.send_frame(transport, frame)
    assert_receive {:codex_transport_frame, ^transport, response}, 5_000
    assert Jason.decode!(response) == frame

    assert identity["pid"] == identity["pgid"]
    assert :ok = stop_supervised(StdioTransport)
  end
end
