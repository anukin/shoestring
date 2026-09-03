defmodule Shoestring.Harness.Capacity.Codex.StdioTransportTest do
  use ExUnit.Case, async: true

  alias Shoestring.Harness.Capacity.Codex.StdioTransport

  describe "initialization and failure handling" do
    test "fails to start when executable does not exist" do
      result =
        StdioTransport.start_link(
          owner: self(),
          command: "non_existent_codex_binary_12345"
        )

      assert result == {:error, :executable_not_found}
    end
  end

  describe "stdio communication with real OS executable" do
    test "spawns cat and exchanges line frames without shell interpolation" do
      cat_path = System.find_executable("cat")
      assert cat_path != nil

      {:ok, transport} =
        StdioTransport.start_link(
          owner: self(),
          executable: cat_path,
          args: []
        )

      # Owner receives connected notification
      assert_receive {:codex_transport_connected, ^transport}

      # Send a JSON frame
      test_payload = %{"method" => "test", "id" => 1}
      assert :ok = StdioTransport.send_frame(transport, test_payload)

      # Expect to receive back the echoed line from cat
      assert_receive {:codex_transport_frame, ^transport, echoed_line}
      assert {:ok, decoded} = Jason.decode(echoed_line)
      assert decoded == test_payload

      # Close transport
      assert :ok = StdioTransport.close(transport)
      assert_receive {:codex_transport_closed, ^transport, _reason}
    end

    test "handles oversized frames safely" do
      cat_path = System.find_executable("cat")
      assert cat_path != nil

      {:ok, transport} =
        StdioTransport.start_link(
          owner: self(),
          executable: cat_path,
          args: [],
          max_frame_size: 20
        )

      assert_receive {:codex_transport_connected, ^transport}

      # Send a line longer than 20 bytes
      long_payload = %{"data" => "this_is_a_very_long_string_exceeding_twenty_bytes"}
      assert :ok = StdioTransport.send_frame(transport, long_payload)

      # Owner should receive an oversized frame error
      assert_receive {:codex_transport_error, ^transport, :oversized_frame}

      # Clean up
      assert :ok = StdioTransport.close(transport)
    end

    test "reports process exit status when target process terminates" do
      sh_path = System.find_executable("sh")
      assert sh_path != nil

      # Spawn sh with -c "exit 42"
      {:ok, transport} =
        StdioTransport.start_link(
          owner: self(),
          executable: sh_path,
          args: ["-c", "exit 42"]
        )

      assert_receive {:codex_transport_connected, ^transport}
      assert_receive {:codex_transport_closed, ^transport, {:exit_status, 42}}
    end
  end
end
