defmodule Shoestring.Harness.FrameCollectorTest do
  @moduledoc """
  `Shoestring.Harness.FrameCollector` against trivial local `python3`
  scripts run through `Shoestring.Elves.PortRunner`: no provider, no network.
  """
  use ExUnit.Case, async: true

  alias Shoestring.Elves.PortRunner
  alias Shoestring.Harness.FrameCollector

  defp spawn!(script) do
    {:ok, runner} = PortRunner.spawn(["python3", "-c", script])
    runner
  end

  defp group_alive?(pgid),
    do: match?({_, 0}, System.cmd("kill", ["-0", "-#{pgid}"], stderr_to_stdout: true))

  # Six 2 MiB frames of command output, then the answer: 12 MiB in all.
  @long """
  import json, sys
  for n in range(6):
      print(json.dumps({"type": "item.completed", "item": {"type": "command_execution", "aggregated_output": "x" * 2097152}}), flush=True)
  print("not json, a diagnostic", flush=True)
  print(json.dumps({"type": "turn.completed", "usage": {"output_tokens": 50000}}), flush=True)
  """

  test "a long run keeps only the frames asked for; what is kept stays bounded" do
    progress_only = fn frame -> frame["item"]["type"] != "command_execution" end
    test = self()

    assert {:ok, [%{"type" => "turn.completed"}]} =
             FrameCollector.collect(spawn!(@long),
               keep: fn frame -> progress_only.(Map.put_new(frame, "item", %{})) end,
               each: &send(test, {:frame, &1["type"]})
             )

    # Every frame was seen as it arrived, kept or not.
    for _ <- 1..6, do: assert_received({:frame, "item.completed"})
    assert_received {:frame, "turn.completed"}

    # Keeping everything, the same run is over the bound and fails, untruncated.
    assert {:error, :output_too_large} = FrameCollector.collect(spawn!(@long))

    # One line over its bound fails even when it would not be kept.
    assert {:error, :output_too_large} =
             FrameCollector.collect(spawn!(@long),
               keep: fn _ -> false end,
               max_line_bytes: 1_048_576
             )
  end

  test "with no deadline it waits for the run; with one, it ends the run's whole group" do
    slow = """
    import json, time
    time.sleep(1.5)
    print(json.dumps({"type": "result"}), flush=True)
    """

    assert {:ok, [%{"type" => "result"}]} = FrameCollector.collect(spawn!(slow), deadline_ms: nil)

    hang = "import subprocess, time; subprocess.Popen(['sleep', '60']); time.sleep(60)"
    runner = spawn!(hang)
    assert {:error, :transport_timeout} = FrameCollector.collect(runner, deadline_ms: 300)
    refute group_alive?(runner.pgid)
  end

  test "a cancelled run ends with its whole process group, children included" do
    script = """
    import json, subprocess, time
    subprocess.Popen(["sleep", "60"])
    print(json.dumps({"type": "started"}), flush=True)
    time.sleep(60)
    """

    test = self()

    # The process that opens the port collects it.
    collector =
      Task.async(fn ->
        runner = spawn!(script)
        send(test, {:pgid, runner.pgid})
        FrameCollector.collect(runner, each: &send(test, {:frame, &1["type"]}))
      end)

    assert_receive {:pgid, pgid}, 5_000
    assert_receive {:frame, "started"}, 5_000
    assert group_alive?(pgid)
    FrameCollector.cancel(collector.pid)
    assert {:error, :cancelled} = Task.await(collector, 15_000)
    refute group_alive?(pgid)
  end

  test "a run that exits non-zero is a transport error" do
    assert {:error, :transport_error} = FrameCollector.collect(spawn!("import sys; sys.exit(3)"))
  end
end
