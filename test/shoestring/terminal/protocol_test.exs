defmodule Shoestring.Terminal.ProtocolTest do
  use ExUnit.Case, async: true
  alias Shoestring.Terminal.Protocol

  test "fragmented and adjacent control/data frames round-trip arbitrary bytes" do
    bytes = :binary.list_to_bin(Enum.to_list(0..255))
    message = %{"op" => "output", "data" => Base.encode64(bytes)}
    {:ok, frame} = Protocol.encode(message)

    {messages, buffer} =
      Enum.reduce(:binary.bin_to_list(frame <> frame), {[], <<>>}, fn byte, {messages, buffer} ->
        {:ok, decoded, buffer} = Protocol.feed(buffer, <<byte>>)
        {messages ++ decoded, buffer}
      end)

    assert [^message, ^message] = messages
    assert buffer == <<>>
    assert Base.decode64!(hd(messages)["data"]) == bytes
  end

  test "oversized length is rejected before receiving or allocating its body" do
    assert {:error, :terminal_frame_too_large} = Protocol.feed(<<>>, <<65_537::32>>)
    assert {:error, :terminal_frame_too_large} = Protocol.feed(<<>>, <<0::32>>)
    assert {:error, :invalid_terminal_frame} = Protocol.feed(<<>>, <<1::32, 255>>)
    assert {:error, :invalid_terminal_frame} = Protocol.feed(<<>>, <<2::32, "[]">>)

    assert {:error, :invalid_terminal_frame} =
             Protocol.encode(%{"data" => String.duplicate("a", 65_536)})
  end
end
