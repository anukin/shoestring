defmodule Shoestring.Elves.ElfLaunchAbortLogTest do
  @moduledoc """
  A launch abort's log line names its persisted error code.

  CI run 35955255945 failed because one Elf launch aborted before
  `run.running`, and its log said only `[warning] elf launch aborted`: the
  cause (`error_code`, `reason`) was Logger metadata, which the default
  formatter does not print. The durable `run.failed` payload had the code;
  the CI log, the only artifact left, did not. So the failure could not be
  attributed.

  LOCK: fails on base `d3fa152` (the message carries no code). Both
  directions are asserted: the bounded code is present, the raw reason
  (here a host path) is absent.
  """
  use Shoestring.DataCase, async: false

  import ExUnit.CaptureLog

  alias Shoestring.Elves
  alias Shoestring.Test.ElvesHelpers

  test "the abort warning names the error code, and not the raw reason" do
    sup = start_supervised!({Shoestring.Elves.Supervisor, name: nil})
    %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()
    request = ElvesHelpers.run_request(goal, task)

    missing_dir =
      Path.join(System.tmp_dir!(), "no-such-workdir-#{System.unique_integer([:positive])}")

    log =
      capture_log([level: :warning], fn ->
        assert {:ok, _pid} =
                 Elves.start_run(request, ElvesHelpers.fake_identity(),
                   supervisor: sup,
                   scenario: ElvesHelpers.custom_scenario(:abort_log, []),
                   command: ["sleep", "30"],
                   runner_opts: [cd: missing_dir, kill_grace_ms: 200, reap_timeout_ms: 2_000],
                   notify: self()
                 )

        assert_receive {:elf_terminal, run_id, %{class: :failed}}, 10_000
        event = ElvesHelpers.terminal_event(goal.id, run_id)
        assert event.payload["error_code"] == "invalid_workdir"
      end)

    assert log =~ "elf launch aborted: invalid_workdir"
    refute log =~ missing_dir
  end
end
