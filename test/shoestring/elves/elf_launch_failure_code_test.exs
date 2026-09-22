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
  - `"an uncontracted stream failure fails as unclassified"` — **lock**
    (twin path through `begin_streaming/1`). Base records the
    `process_launch_failed` default where `launch_failed_unclassified` is
    asserted; the raw adapter text is absent either way.
  - `"an append_running failure keeps its attributable code"` — **lock**
    (twin path through `launch_fresh/1`'s `append_running/1` clause). Base
    records the `process_launch_failed` default where
    `trusted_reference_not_owned` is asserted. The trigger (a run row moved
    to another goal mid-launch) is a vehicle: the lock is the branch
    mapping, and no false terminal is fabricated when the run reference
    itself is unowned.
  - `"an adapter cancellation at start records cancelled"` — **lock
    against the parent commit** (`abab95e`, whose abort log used dot
    access): there the launch handler raises `KeyError` and misreports the
    cancellation as `transport/elf_launch_crashed` with no notification,
    where `run.cancelled` is asserted. It passes on base `733c39b`
    (documentation there), which never logged the terminal.

  Hermetic: `Fake` adapter, trivial local commands, no provider CLI, no
  network. No sleeps; terminals arrive via `notify` messages and monitors.
  """

  use Shoestring.DataCase, async: false

  import Ecto.Query

  alias Shoestring.Elves
  alias Shoestring.Harness.{Error, Fake, RunIdentity, RunRequest}
  alias Shoestring.Test.ElvesHelpers
  alias Shoestring.Test.Fixtures.FakeHelpers

  defmodule StreamBoomAdapter do
    @moduledoc false
    @behaviour Shoestring.Harness.Adapter

    def identity, do: Fake.identity()
    def capabilities, do: Fake.capabilities()
    def probe(opts), do: Fake.probe(opts)
    def start(%RunRequest{} = request, opts), do: Fake.start(request, opts)
    def status(%RunIdentity{} = identity, opts), do: Fake.status(identity, opts)

    def stream(%RunIdentity{}, _opts),
      do: {:error, "Custom Launch Boom in /home/operator/private-worktree"}
  end

  defmodule BlockingStartAdapter do
    @moduledoc false
    @behaviour Shoestring.Harness.Adapter

    def identity, do: Fake.identity()
    def capabilities, do: Fake.capabilities()
    def probe(opts), do: Fake.probe(opts)
    def status(%RunIdentity{} = identity, opts), do: Fake.status(identity, opts)
    def stream(%RunIdentity{} = identity, opts), do: Fake.stream(identity, opts)

    # Blocks the Elf mid-launch (inside `start_adapter/1`) until the test
    # releases it, so the test can deterministically rearrange durable state
    # that `append_running/1` will then observe. Synchronized by messages,
    # never by sleeps.
    def start(%RunRequest{} = request, opts) do
      send(opts.test_pid, {:adapter_start_entered, self()})

      receive do
        :release_adapter -> Fake.start(request, opts)
      end
    end
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

  test "an uncontracted stream failure fails as unclassified", %{
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
    assert event.payload["error_code"] == "launch_failed_unclassified"

    # Both directions: the safe constant is present AND the raw adapter
    # text (with its operator path) is absent.
    refute inspect(event.payload) =~ "private-worktree"
    refute inspect(event.payload) =~ "Custom Launch Boom"
  end

  test "an append_running failure keeps its attributable code", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, elf_pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               adapter: BlockingStartAdapter,
               adapter_opts: %{
                 scenario: ElvesHelpers.custom_scenario(:append_running, []),
                 test_pid: self()
               },
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               notify: self()
             )

    assert_receive {:adapter_start_entered, ^elf_pid}, 10_000

    # The run row is reassigned to another goal while the Elf is parked in
    # adapter start: `append_running/1` then observes the failure
    # deterministically as `{:trusted_reference_not_owned, :run_id}`.
    other_goal = FakeHelpers.insert_goal(Ecto.UUID.generate())
    run_id = ElvesHelpers.run_id_for_dispatch(request.dispatch_id)
    assert is_binary(run_id)

    {1, _} =
      Repo.update_all(
        from(run in Shoestring.Harness.RunRecord, where: run.id == ^run_id),
        set: [goal_id: other_goal.id]
      )

    send(elf_pid, :release_adapter)

    assert_receive {:elf_terminal, ^run_id,
                    %{class: :failed, error_code: "trusted_reference_not_owned"}},
                   10_000

    # No false durable claim: with the run reference itself unowned, no
    # terminal event is fabricated for the original goal.
    assert ElvesHelpers.terminal_event(goal.id, run_id) == nil
  end

  test "an adapter cancellation at start records cancelled", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    request = ElvesHelpers.run_request(goal, task)

    scenario =
      ElvesHelpers.custom_scenario(:cancelled_start, [],
        start_error: Error.new(:cancelled, "cancelled", "adapter cancelled before start")
      )

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               notify: self()
             )

    run_id = ElvesHelpers.run_id_for_dispatch(request.dispatch_id)
    assert is_binary(run_id)

    assert {:ok, event} =
             ElvesHelpers.wait_until(fn -> ElvesHelpers.terminal_event(goal.id, run_id) end)

    assert event.type == "run.cancelled"
    assert_receive {:elf_terminal, ^run_id, %{class: :cancelled}}, 10_000
  end
end
