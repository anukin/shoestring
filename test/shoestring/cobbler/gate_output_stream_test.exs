defmodule Shoestring.Cobbler.GateOutputStreamTest do
  use ExUnit.Case, async: true

  alias Shoestring.Cobbler.{GateOutput, GateOutputStream}
  alias Shoestring.Harness.Security

  test "all port split points preserve ordinary output and redact split credentials" do
    input =
      "before\npassword=\nsynthetic-password\nBearer\nsynthetic-bearer\n" <>
        "cookie:\nsynthetic-cookie\nrefresh_token=synthetic-refresh\n" <>
        "prefixedpassword=\nsynthetic-prefixed\nxBearer\nsynthetic-prefixed-bearer\nafter\n"

    for split <- 0..byte_size(input) do
      first = binary_part(input, 0, split)
      second = binary_part(input, split, byte_size(input) - split)
      output = stream([first, second])

      assert output =~ "before\n"
      assert output =~ "after\n"

      for secret <-
            ~w(synthetic-password synthetic-bearer synthetic-cookie synthetic-refresh synthetic-prefixed),
          do: refute(output =~ secret)

      refute Security.secret_value?(output)
    end

    assert stream(for <<byte <- input>>, do: <<byte>>) == GateOutput.redact(input)
  end

  test "an unfinished line is withheld until the line or invocation ends" do
    {callback, state} = sink()
    assert {:ok, state} = callback.({:data, "ready\npartial"}, state)
    assert_receive {:chunk, 1, "ready\n"}
    refute_receive {:chunk, _, _}
    assert {:ok, _state} = callback.(:eof, state)
    assert_receive {:chunk, 2, "partial"}
  end

  test "UTF-8 characters split across port chunks are retained and invalid bytes are withheld" do
    input = "ready café\ndone\n"
    assert stream(for <<byte <- input>>, do: <<byte>>) == input

    assert stream(["ready\n", <<255>>, "\n", "done\n"]) ==
             "ready\n[REDACTED: invalid UTF-8 gate output]\ndone\n"
  end

  defp stream(chunks) do
    {callback, state} = sink()

    state =
      Enum.reduce(chunks, state, fn bytes, state ->
        assert {:ok, state} = callback.({:data, bytes}, state)
        state
      end)

    assert {:ok, _state} = callback.(:eof, state)
    collect([])
  end

  defp sink do
    caller = self()

    GateOutputStream.new(fn bytes, number ->
      send(caller, {:chunk, number, bytes})
      :ok
    end)
  end

  defp collect(parts) do
    receive do
      {:chunk, _number, bytes} -> collect([bytes | parts])
    after
      0 -> parts |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end
end
