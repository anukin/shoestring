defmodule Shoestring.Elves.ElfClaudeDeclineQuiescenceTest do
  @moduledoc """
  Hermetic declined-lease quiescence tests for provider sessions.

  After a lease decline the run sleeps durably (`run.pausing` /
  `run.suspended` plus a sleep wake) and the Elf must stop supervising once
  its buffer drains — leaving no useful-work Elf and no owned process group
  behind, and settling through the canonical suspension state (no terminal).
  Observed live against a ClaudeHeadless receiver in
  `plans/evidence/05-quota-aware-mvp/live-cross-provider-handoff.md` §7.5:
  the OS process was gone, the run was suspended, and the Elf was still
  supervising 25 minutes later with no terminal and no further events.

  The strand: a session that is alive but already terminal (notably the
  ClaudeHeadless immediate safe-stop, which kills the group and marks the
  session `cancelled` without emitting a further stream event) never reads
  as `:none` to the old liveness check, so the quiet exit never fired and
  the Elf waited on work that could never arrive.

  Lock-vs-documentation ledger (verified against base `733c39b`):

  - `"a declined run with a terminal Claude session exits quietly"` —
    **lock**. Base never exits: the DOWN assertion times out where it is
    asserted.
  - `"a declined run with a terminal Codex session exits quietly"` —
    **lock** (twin provider through the same helper). Base lingers the same
    way.
  - `"a declined run with a working session keeps supervising"` —
    **documentation**. Passes on base too; it pins the fail-safe direction:
    a merely quiet but non-terminal session never triggers the quiet exit
    (staleness is evidence, never a trigger), and explicit cancellation
    still owns and terminates the whole group.

  Hermetic: `Fake` adapter legs, trivial local commands, ETS session
  doubles — never a provider CLI, never the network. No sleeps; Elf exit
  is observed with monitors and state synchronization.
  """

  use Shoestring.DataCase, async: false

  alias Shoestring.Cobbler.{Leases, WakeupRecord}
  alias Shoestring.Elves
  alias Shoestring.Elves.Elf
  alias Shoestring.Harness.{CapacitySnapshot, ExecutionLease, ExecutionLeaseRecord}
  alias Shoestring.Harness.{Projector, RunRecord}
  alias Shoestring.Harness.Fake.Scenario
  alias Shoestring.Repo
  alias Shoestring.Elves.PortRunner
  alias Shoestring.Test.CobblerHelpers
  alias Shoestring.Test.ElvesHelpers
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Test.FixedClock

  @runner_opts [kill_grace_ms: 200, reap_timeout_ms: 2_000]
  @interval_ms 200

  setup do
    sup = start_supervised!({Shoestring.Elves.Supervisor, name: nil})
    %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()
    {:ok, sup: sup, goal: goal, task: task}
  end

  test "a declined run with a terminal Claude session exits quietly", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    declined =
      start_declined_run(sup, goal, task, :decline_claude_quiet, fn dispatch_id ->
        register_terminal_session_double(
          :claude_headless_sessions,
          dispatch_id,
          &Shoestring.Harness.ClaudeHeadless.lookup_session/1,
          :cancelled
        )
      end)

    run_id = declined.run_id
    elf_pid = declined.elf_pid
    request = declined.request

    ref = Process.monitor(elf_pid)
    assert_receive {:DOWN, ^ref, :process, ^elf_pid, :normal}, 15_000
    assert_received :safe_stop_requested
    refute_received {:elf_terminal, ^run_id, _terminal}

    # Canonical suspension settle: pausing then suspended, no terminal, and
    # the sleep wake owns the future.
    assert count_types(goal.id, run_id, ["run.pausing"]) == 1
    assert count_types(goal.id, run_id, ["run.suspended"]) == 1
    assert count_types(goal.id, run_id, ["run.completed"]) == 0
    assert count_types(goal.id, run_id, ["run.failed"]) == 0

    wakeup = Repo.get_by!(WakeupRecord, run_id: run_id)
    assert wakeup.command_id == "elf-lease-decline:#{request.dispatch_id}"
    assert wakeup.status == "scheduled"

    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)
    assert Repo.get_by!(RunRecord, id: run_id).status == "suspended"

    # No owned process group left running: the reaped pgid is gone.
    if pgid = ElvesHelpers.recorded_pgid(goal.id, run_id) do
      refute PortRunner.alive_id?(pgid)
    end
  end

  test "a declined run with a terminal Codex session exits quietly", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    declined =
      start_declined_run(sup, goal, task, :decline_codex_quiet, fn dispatch_id ->
        register_terminal_session_double(
          :codex_app_server_sessions,
          dispatch_id,
          &Shoestring.Harness.CodexAppServer.lookup_session/1,
          :interrupted
        )
      end)

    run_id = declined.run_id
    elf_pid = declined.elf_pid
    request = declined.request

    ref = Process.monitor(elf_pid)
    assert_receive {:DOWN, ^ref, :process, ^elf_pid, :normal}, 15_000
    assert_received :safe_stop_requested
    refute_received {:elf_terminal, ^run_id, _terminal}

    assert count_types(goal.id, run_id, ["run.suspended"]) == 1
    assert ElvesHelpers.terminal_event(goal.id, run_id) == nil

    wakeup = Repo.get_by!(WakeupRecord, run_id: run_id)
    assert wakeup.command_id == "elf-lease-decline:#{request.dispatch_id}"
    assert wakeup.status == "scheduled"

    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)
    assert Repo.get_by!(RunRecord, id: run_id).status == "suspended"
  end

  test "a declined run with a working session keeps supervising", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    declined =
      start_declined_run(sup, goal, task, :decline_working_session, fn dispatch_id ->
        register_terminal_session_double(
          :claude_headless_sessions,
          dispatch_id,
          &Shoestring.Harness.ClaudeHeadless.lookup_session/1,
          :running
        )
      end)

    run_id = declined.run_id
    elf_pid = declined.elf_pid

    # The decline still suspends and wakes — but the Elf stays on duty while
    # the session reports useful work.
    assert {:ok, true} =
             ElvesHelpers.wait_until(fn ->
               if count_types(goal.id, run_id, ["run.suspended"]) == 1, do: true
             end)

    _ = :sys.get_state(elf_pid)
    assert Process.alive?(elf_pid)
    assert ElvesHelpers.terminal_event(goal.id, run_id) == nil

    pgid = ElvesHelpers.recorded_pgid(goal.id, run_id)
    assert pgid != nil
    assert PortRunner.alive_id?(pgid)

    # Explicit cancellation still owns and terminates the whole group.
    assert {:ok, :cancelled} = Elf.cancel(elf_pid)
    assert_receive {:elf_terminal, ^run_id, %{class: :cancelled}}, 15_000
    refute PortRunner.alive_id?(pgid)
  end

  # -- Helpers --

  # Starts a Fake leg that declines at its boundary (response_budget 2, zero
  # reserve, breached capacity) with a verdict-free stream, registers the
  # given session double, and waits until the run is streaming. Returns the
  # run id, Elf pid, and request for the caller's settle assertions.
  defp start_declined_run(sup, goal, task, name, register_session) do
    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id, used_percent: 95.0)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    scenario =
      fake_scenario(name, breached_snapshot(fresh_id), [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        Scenario.output_event("one", source_event_id: "evt-out-1"),
        Scenario.output_event("two", source_event_id: "evt-out-2"),
        Scenario.output_event("three", source_event_id: "evt-out-3")
      ])

    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, elf_pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               scenario: scenario,
               command: ["sleep", "30"],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    run_id = wait_running(goal, request.dispatch_id)
    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    grant_for_run!(goal, run_id, fresh_id,
      response_budget: 2,
      tool_budget: 25,
      reserves: %{response: 0, tool: 0},
      checkpoint_cadence: 100,
      deadline: DateTime.add(FixedClock.now(), 3_600, :second)
    )

    register_session.(request.dispatch_id)

    %{run_id: run_id, elf_pid: elf_pid, request: request}
  end

  defp wait_running(goal, dispatch_id) do
    assert {:ok, run_id} =
             ElvesHelpers.wait_until(fn -> ElvesHelpers.run_id_for_dispatch(dispatch_id) end)

    assert {:ok, _pgid} =
             ElvesHelpers.wait_until(fn -> ElvesHelpers.recorded_pgid(goal.id, run_id) end)

    run_id
  end

  defp fake_scenario(name, capacity, events) do
    %Scenario{
      name: name,
      capacity: capacity,
      start_error: nil,
      resume_error: nil,
      provider_session_id: "fake-session-#{name}",
      events: events,
      delivery_modifier: :none
    }
  end

  # A session double that answers the decline's safe-stop request and then
  # reports the given status: terminal (`:cancelled` / `:interrupted`) for
  # the quiescence locks, still-working (`:running`) for the control.
  defp register_terminal_session_double(table, id, ensure_lookup, status) do
    _ = ensure_lookup.(Ecto.UUID.generate())

    test = self()
    double = spawn(fn -> terminal_session_loop(test, status) end)

    :ets.insert(table, {id, double})

    on_exit(fn ->
      if :ets.info(table) != :undefined do
        :ets.delete(table, id)
      end

      if Process.alive?(double), do: Process.exit(double, :kill)
    end)

    :ok
  end

  defp terminal_session_loop(test, status) do
    receive do
      {:"$gen_call", {caller, ref}, :request_safe_stop} ->
        send(test, :safe_stop_requested)
        send(caller, {ref, {:ok, :stop_requested}})
        terminal_session_loop(test, status)

      {:"$gen_call", {caller, ref}, :status} ->
        send(caller, {ref, {:ok, %{status: status, stop_requested: :safe_boundary}}})
        terminal_session_loop(test, status)
    end
  end

  defp breached_snapshot(snapshot_id), do: codex_snapshot(snapshot_id, 95.0)

  defp codex_snapshot(snapshot_id, used_percent) do
    now = FixedClock.now()

    {:ok, snapshot} =
      CapacitySnapshot.new(
        %{
          version: 2,
          snapshot_id: snapshot_id,
          capacity_state: :observed,
          windows: [
            %{kind: "five_hour", state: :observed, used_percent: used_percent, reset_at: nil},
            %{kind: "weekly", state: :observed, used_percent: 30.0, reset_at: nil}
          ],
          observed_at: now,
          freshness: %{max_age_seconds: 300},
          source: %{
            adapter_id: "shoestring.harness.fake",
            provider_id: "codex",
            invocation_mode: "app_server",
            event: :explicit_read
          },
          scope: "account:codex",
          confidence: :high,
          support_tier: :proactive,
          compatibility_state: :compatible,
          reason: nil,
          extensions: %{}
        },
        now: now
      )

    snapshot
  end

  defp grant_for_run!(goal, run_id, admitted_snapshot_id, opts) do
    decision_id = Ecto.UUID.generate()
    grant_id = Ecto.UUID.generate()

    admission =
      CobblerHelpers.append_admission_event!(
        goal.id,
        CobblerHelpers.admission_payload()
        |> Map.merge(%{
          "decision_id" => decision_id,
          "result" => "admit",
          "reason_code" => "automatic_admission_eligible",
          "explanation" => "Elf Claude decline quiescence test admission",
          "observation" => %{
            "snapshot_id" => admitted_snapshot_id,
            "confidence" => "high",
            "freshness" => "fresh"
          },
          "proposed_bounds" => %{
            "response_budget" => Keyword.fetch!(opts, :response_budget),
            "tool_budget" => Keyword.fetch!(opts, :tool_budget),
            "deadline" => DateTime.to_iso8601(Keyword.fetch!(opts, :deadline)),
            "checkpoint_cadence" => Keyword.fetch!(opts, :checkpoint_cadence),
            "reserves" => %{
              "response" => get_in(opts, [:reserves, :response]),
              "tool" => get_in(opts, [:reserves, :tool])
            }
          }
        })
      )

    reserves = Keyword.fetch!(opts, :reserves)

    {:ok, lease} =
      ExecutionLease.new(%{
        version: 1,
        grant_id: grant_id,
        run_id: run_id,
        admitted_snapshot_id: admitted_snapshot_id,
        reserves: %{response: reserves.response, tool: reserves.tool},
        response_budget: Keyword.fetch!(opts, :response_budget),
        tool_budget: Keyword.fetch!(opts, :tool_budget),
        deadline: Keyword.fetch!(opts, :deadline),
        checkpoint_cadence: Keyword.fetch!(opts, :checkpoint_cadence),
        renewal_state: :none,
        extensions: %{
          "cobbler.lease:admission_decision_id" => decision_id,
          "cobbler.lease:admission_event_id" => admission.id,
          "cobbler.lease:candidate" => "codex/codex_app_server",
          "cobbler.lease:scope" => "account:codex"
        }
      })

    assert {:ok, %{grant_id: ^grant_id}} = Leases.grant(goal.id, lease)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)
    assert Repo.get!(ExecutionLeaseRecord, grant_id).status == "active"

    %{grant_id: grant_id, admission_id: admission.id}
  end

  defp count_types(goal_id, run_id, types) do
    ElvesHelpers.count_events(goal_id, run_id, types)
  end
end
