defmodule Shoestring.Harness.ClaudeFixtureLauncherTest do
  use ExUnit.Case, async: true

  test "live evaluation launcher refuses shared or redirected storage using local fixtures" do
    assert {:ok, %{exit_status: 0, output: output}} =
             Shoestring.Cobbler.GateProcess.run(
               [
                 "python3",
                 "-B",
                 "-m",
                 "unittest",
                 "discover",
                 "-s",
                 "tools/live_eval",
                 "-p",
                 "test_claude_fixture_launcher.py"
               ],
               File.cwd!(),
               30_000,
               65_536
             )

    assert output =~ "Ran 5 tests"
    assert output =~ "OK"
  end
end
