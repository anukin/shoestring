defmodule Shoestring.Terminal.Protocol do
  @moduledoc "Version 1: big-endian uint32 length followed by bounded UTF-8 JSON; terminal bytes are base64."
  @version 1
  @max_frame 65_536
  @max_chunk 262_144

  def version, do: @version
  def max_frame, do: @max_frame

  def encode(%{} = message) do
    case Jason.encode(message) do
      {:ok, body} when byte_size(body) in 1..@max_frame ->
        {:ok, <<byte_size(body)::unsigned-big-32, body::binary>>}

      _ ->
        {:error, :invalid_terminal_frame}
    end
  end

  def feed(buffer, bytes) when is_binary(buffer) and is_binary(bytes) do
    if byte_size(bytes) <= @max_chunk and byte_size(buffer) <= @max_frame + 4,
      do: decode(buffer <> bytes, []),
      else: {:error, :terminal_frame_too_large}
  end

  defp decode(<<size::unsigned-big-32, _::binary>>, _acc)
       when size == 0 or size > @max_frame,
       do: {:error, :terminal_frame_too_large}

  defp decode(<<size::unsigned-big-32, rest::binary>> = buffer, acc) do
    if byte_size(rest) >= size do
      <<body::binary-size(size), tail::binary>> = rest

      case Jason.decode(body) do
        {:ok, %{} = message} -> decode(tail, [message | acc])
        _ -> {:error, :invalid_terminal_frame}
      end
    else
      {:ok, Enum.reverse(acc), buffer}
    end
  end

  defp decode(buffer, acc), do: {:ok, Enum.reverse(acc), buffer}
end
