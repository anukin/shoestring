defmodule Shoestring.Elves.LaunchFailureCodeTest do
  @moduledoc """
  Hermetic Elf launch-failure attribution tests.

  `Shoestring.Elves.Elf.launch_fresh/1` used to collapse every unrecognized
  launch reason to the `process_launch_failed` catch-all (and
  `begin_streaming/1` discarded the stream reason entirely), so an operator
  reading the trajectory could not tell what failed — the honest unknown
  recorded in `plans/evidence/05-quota-aware-mvp/live-cross-provider-handoff.md`
  §7.4. Structured reasons now persist their attributable head
  (`invalid_workdir`, `writer_unavailable`, sanitized adapter text, ...) while
  tuple payloads (paths, raw port errors, changesets) stay server-side in the
  warning log, redacted, so terminal projection stays safe.

  Lock-vs-documentation ledger (verified against base `733c39b`):

  - `"an invalid workdir fails as invalid_workdir"` — **lock**. Base records
    `transport/process_launch_failed` where `transport/invalid_workdir` is
    asserted.
  - `"the bad path never reaches the trajectory"` — **lock** (same collapse:
    base records the catch-all where `invalid_workdir` is asserted) and the
    both-directions redaction control: the sensitive path is gone AND the
    required attribution is still present.
  - `"an uncontracted stream failure fails with its sanitized code"` —
    **lock** (twin path through `begin_streaming/1`). Base records the
    `process_launch_failed` default where `"custom_launch_boom"` is
    asserted.

  Hermetic: `Fake` adapter, trivial local commands, no provider CLI, no
  network. No sleeps; terminals arrive via `notify` messages and monitors.
  """

  use Shoestring.DataCase, async: false

  alias Shoestring.Elves
  alias Shoestring.Harness.{Fake, RunIdentity, RunRequest}
  alias Shoestring.Test.ElvesHelpers

  defmodule StreamBoomAdapter do
    @moduledoc false
    @behaviour Shoestring.Harness.Adapter

    def identity, do: Fake.identity()
    def capabilities, do: Fake.capabilities()
    def probe(opts), do: Fake.probe(opts)
    def start(%RunRequest{} = request, opts), do: Fake.start(request, opts)
    def status(%RunIdentity{} = identity, opts), do: Fake.status(identity, opts)
    def stream(%RunIdentity{}, _opts), do: {:error, "Custom Launch Boom!"}
  end

  @runner_opts [kill_grace_ms: 200, reap_timeout_ms: 2_000]

  setup do
    sup = start_supervised!({Shoestring.Elves.Supervisor, name: nil})
    %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()
    {:ok, sup: sup, goal: goal, task: task}
  end

  test "an invalid workdir fails as invalid_workdir", %{sup: sup, goal: goal, task: task} do
    bad_dir = "/nonexistent-shoestring-launch-#{Ecto.UUID.generate()}"
    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: ElvesHelpers.custom_scenario(:bad_workdir, []),
               command: ["sleep", "30"],
               runner_opts: [cd: bad_dir] ++ @runner_opts,
               notify: self()
             )

    assert_receive {:elf_terminal, run_id, %{class: :failed}}, 10_000

    event = ElvesHelpers.terminal_event(goal.id, run_id)
    assert event.type == "run.failed"
    assert event.payload["error_category"] == "transport"
    assert event.payload["error_code"] == "invalid_workdir"

    # No OS process was ever spawned for a refused launch.
    assert ElvesHelpers.count_events(goal.id, run_id, ["run.running"]) == 0
    assert ElvesHelpers.recorded_pgid(goal.id, run_id) == nil
  end

  test "the bad path never reaches the trajectory", %{sup: sup, goal: goal, task: task} do
    bad_dir = "/nonexistent-shoestring-secret-#{Ecto.UUID.generate()}"
    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: ElvesHelpers.custom_scenario(:bad_workdir_redaction, []),
               command: ["sleep", "30"],
               runner_opts: [cd: bad_dir] ++ @runner_opts,
               notify: self()
             )

    assert_receive {:elf_terminal, run_id, %{class: :failed}}, 10_000

    event = ElvesHelpers.terminal_event(goal.id, run_id)
    assert event.payload["error_code"] == "invalid_workdir"
    refute event.payload["error_code"] =~ "nonexistent-shoestring-secret"
    refute inspect(event.payload) =~ "nonexistent-shoestring-secret"
  end

  test "an uncontracted stream failure fails with its sanitized code", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               adapter: StreamBoomAdapter,
               scenario: ElvesHelpers.custom_scenario(:stream_boom, []),
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               notify: self()
             )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)

    assert_receive {:elf_terminal, run_id, %{class: :failed}}, 10_000

    event = ElvesHelpers.terminal_event(goal.id, run_id)
    assert event.type == "run.failed"
    assert event.payload["error_category"] == "transport"
    assert event.payload["error_code"] == "custom_launch_boom"
  end
end
