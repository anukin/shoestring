defmodule Shoestring.Cobbler.GateOutputStream do
  @moduledoc false

  alias Shoestring.Cobbler.GateOutput

  # A credential label can be followed by whitespace/newlines before its
  # value. Keep that suffix until the value arrives, so port chunk boundaries
  # cannot separate a label from the secret it protects.
  @unfinished_secret ~r/(?:bearer|api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|secret|cookie|authorization)\s*(?:[:=]\s*)?\z/i

  def new(writer) when is_function(writer, 2),
    do: {&consume/2, %{pending: "", chunk: 0, writer: writer}}

  defp consume({:data, data}, state) do
    pending = state.pending <> data

    case :binary.matches(pending, "\n") do
      [] ->
        {:ok, %{state | pending: pending}}

      matches ->
        {last, 1} = List.last(matches)
        complete = binary_part(pending, 0, last + 1)

        if String.valid?(complete) and Regex.match?(@unfinished_secret, complete) do
          {:ok, %{state | pending: pending}}
        else
          rest = binary_part(pending, last + 1, byte_size(pending) - last - 1)
          emit(%{state | pending: rest}, complete)
        end
    end
  end

  defp consume(:eof, state), do: emit(%{state | pending: ""}, state.pending)

  defp emit(state, ""), do: {:ok, state}

  defp emit(state, bytes) do
    with :ok <- state.writer.(GateOutput.redact(bytes), state.chunk + 1) do
      {:ok, %{state | chunk: state.chunk + 1}}
    end
  end
end
