defmodule Shoestring.Harness.ClaudeHeadless.OneShotTest do
  @moduledoc """
  One-shot Claude calls (planner, EXPLORE, REVIEW) read stream-json, so
  Claude's usage reports in it become capacity readings. A scripted
  stand-in prints the frames Claude Code 2.1.310 printed live
  (`test/fixtures/capacity/claude/headless-rate-limit-event-2.1.310-live.json`);
  the real CLI and the network are never used.
  """
  use ExUnit.Case, async: true

  alias Shoestring.Harness.ClaudeHeadless.OneShot

  @fixture Path.expand(
             "../../../fixtures/capacity/claude/headless-rate-limit-event-2.1.310-live.json",
             __DIR__
           )

  setup do
    dir = Path.join(System.tmp_dir!(), "shoestring-one-shot-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp standin(dir, frames) do
    path = Path.join(dir, "claude")
    lines = Enum.map_join(frames, "\n", &Jason.encode!/1)
    File.write!(path, "#!/bin/sh\ncat <<'FRAMES'\n#{lines}\nFRAMES\n")
    File.chmod!(path, 0o755)
    path
  end

  defp call(endpoint, dir, sink) do
    OneShot.call(%{
      endpoint: endpoint,
      model: "opus",
      schema: %{"type" => "object"},
      system_prompt: "s",
      prompt: "p",
      max_output_tokens: 4096,
      timeout_ms: 30_000,
      scratch_prefix: "one-shot-test",
      workdir: dir,
      capacity_sink: sink
    })
  end

  defp result,
    do: %{
      "type" => "result",
      "subtype" => "success",
      "is_error" => false,
      "usage" => %{"output_tokens" => 7},
      "structured_output" => %{"summary" => "ok"}
    }

  test "a usage report in the stream is recorded and the result still returned", %{dir: dir} do
    rate_limit = @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("payload")
    system = %{"type" => "system", "subtype" => "init", "claude_code_version" => "2.1.310"}
    test = self()

    sink = fn snapshot ->
      send(test, {:reading, snapshot})
      {:ok, :recorded, snapshot}
    end

    endpoint = standin(dir, [system, rate_limit, result()])
    assert {:ok, %{json: json, output_tokens: 7}} = call(endpoint, dir, sink)
    assert Jason.decode!(json) == %{"summary" => "ok"}

    assert_receive {:reading, snapshot}
    assert %{"capacity:cli_version" => "2.1.310"} = snapshot.extensions

    assert %{used_percent: 15.0, state: :observed} =
             Enum.find(snapshot.windows, &(&1.kind == "five_hour"))
  end

  test "each tool the explorer uses is reported as it happens", %{dir: dir} do
    test = self()

    tool_use = %{
      "type" => "assistant",
      "message" => %{
        "content" => [
          %{"type" => "tool_use", "name" => "Read", "input" => %{"file_path" => "calc.py"}}
        ]
      }
    }

    endpoint = standin(dir, [tool_use, result()])

    input = %{
      endpoint: endpoint,
      model: "opus",
      schema: %{"type" => "object"},
      system_prompt: "s",
      prompt: "p",
      max_output_tokens: 4096,
      timeout_ms: 30_000,
      scratch_prefix: "one-shot-test",
      workdir: dir,
      capacity_sink: nil,
      progress: &send(test, {:step, &1})
    }

    assert {:ok, _} = OneShot.call(input)
    assert_received {:step, "Read calc.py"}
  end

  test "no report records nothing, and a failing sink never fails the call", %{dir: dir} do
    test = self()
    endpoint = standin(dir, [result()])
    assert {:ok, _} = call(endpoint, dir, fn snapshot -> send(test, {:reading, snapshot}) end)
    refute_received {:reading, _}

    rate_limit = @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("payload")
    endpoint = standin(dir, [rate_limit, result()])
    assert {:ok, _} = call(endpoint, dir, fn _snapshot -> raise "sink down" end)
  end
end
