defmodule Shoestring.Cobbler.GateProcessTest do
  use ExUnit.Case, async: true
  alias Shoestring.Cobbler.GateProcess

  test "collects bounded output and the actual exit status" do
    assert {:ok, %{exit_status: 7, output: "gate output", duration_ms: duration}} =
             GateProcess.run(
               ["python3", "-c", "import sys; print('gate output', end=''); sys.exit(7)"],
               File.cwd!(),
               5_000,
               1024
             )

    assert duration >= 0
  end

  test "output overflow fails immediately and terminates its command" do
    assert {:error, {:gate_output_oversized, %{bytes: bytes}}} =
             GateProcess.run(
               ["python3", "-c", "import os; os.write(1, b'x' * 65537)"],
               File.cwd!(),
               5_000,
               65_536
             )

    assert bytes > 65_536
  end

  test "timeout kills the group including a descendant ignoring TERM" do
    marker = Path.join(System.tmp_dir!(), "gate-group-#{Ecto.UUID.generate()}")

    script = """
    import os, signal, sys
    rd, wr = os.pipe()
    if os.fork() == 0:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        os.write(wr, b'ready')
        signal.pause()
    else:
        os.read(rd, 5)
        with open(sys.argv[1], 'w') as file:
            file.write(str(os.getpgrp()))
        signal.pause()
    """

    assert {:error, {:gate_timeout, %{timeout_ms: 1_000}}} =
             GateProcess.run(["python3", "-c", script, marker], File.cwd!(), 1_000, 1024)

    pgid = marker |> File.read!() |> String.to_integer()
    # SIGKILL has been delivered; ps can still report an unreaped orphan zombie.
    {output, _} = System.cmd("ps", ["-axo", "pgid=,stat="], stderr_to_stdout: true)

    states =
      output
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case String.split(line) do
          [group, state] -> if group == to_string(pgid), do: [state], else: []
          _ -> []
        end
      end)

    assert Enum.all?(states, &String.starts_with?(&1, "Z"))
  end
end
