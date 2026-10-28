defmodule Shoestring.Cobbler.PlannerCodexCaptureTest do
  use ExUnit.Case, async: false

  alias Shoestring.Cobbler.GateProcess

  test "isolated proposal capture passes hermetic Python checks without a provider" do
    argv = [
      "python3",
      "-B",
      "-m",
      "unittest",
      "discover",
      "-s",
      "tools/planner_eval",
      "-p",
      "test_codex_proposal.py"
    ]

    assert {:ok, %{exit_status: 0, output: output}} =
             GateProcess.run(argv, File.cwd!(), 20_000, 65_536)

    assert output =~ "Ran 14 tests"
    assert output =~ "OK"
  end
end
