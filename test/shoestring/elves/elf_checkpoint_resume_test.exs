defmodule Shoestring.Elves.PoisonCheckpointRepo do
  @moduledoc false
  # Test-only repo wrapper for checkpoint-persistence failure injection.
  #
  # Every read delegates to `Shoestring.Repo` except the first
  # `checkpoint.created` idempotency lookups (count held by the
  # `:poison_checkpoint_gate` Agent), which return a corrupt row (empty
  # payload) that fails the `Checkpoints` replay rebuild. That exercises
  # the exact `Checkpoints.record` replay-failure path — corrupt or
  # unreadable persisted checkpoint — identically on any tree, with no
  # timing hooks and no writer seam: later lookups delegate, so a retry
  # after the gate is spent can recover through the idempotent writer.
  alias Shoestring.Trajectory.TrajectoryEvent

  @repo Shoestring.Repo
  @gate :poison_checkpoint_gate

  def get_by(schema, clauses, opts \\ [])

  def get_by(TrajectoryEvent, clauses, _opts) when is_list(clauses) do
    if checkpoint_lookup?(clauses) and consume_poison() do
      %TrajectoryEvent{payload: %{}, idempotency_key: Keyword.get(clauses, :idempotency_key)}
    else
      @repo.get_by(TrajectoryEvent, clauses)
    end
  end

  def get_by(schema, clauses, _opts), do: @repo.get_by(schema, clauses)

  def get(schema, id, opts \\ []), do: @repo.get(schema, id, opts)
  def one(query, opts \\ []), do: @repo.one(query, opts)
  def all(query, opts \\ []), do: @repo.all(query, opts)
  def exists?(query, opts \\ []), do: @repo.exists?(query, opts)
  def update(changeset, opts \\ []), do: @repo.update(changeset, opts)

  defp checkpoint_lookup?(clauses) do
    case Keyword.get(clauses, :idempotency_key) do
      "checkpoint-created:" <> _ -> true
      _ -> false
    end
  end

  defp consume_poison do
    Agent.get_and_update(@gate, fn
      0 -> {false, 0}
      n when n > 0 -> {true, n - 1}
    end)
  end
end

defmodule Shoestring.Elves.ElfCheckpointResumeTest do
  @moduledoc """
  Hermetic Elf tests for reliable iteration-5 checkpoints (finding:
  checkpoint/resume round).

  Failure injection: `Shoestring.Elves.PoisonCheckpointRepo` (above)
  returns a corrupt checkpoint row for the first checkpoint idempotency
  lookups, failing the `Checkpoints.record` replay rebuild — the same
  persistence call the Elf makes on every tree. No writer seam, no timing
  hooks: later lookups delegate, so a retry can recover. The Elf under
  test is pointed at the wrapper with `:sys.replace_state/2` after its
  run intent is durable (all pre-decline behavior is identical under the
  wrapper, which delegates everything else).

  - Quota-path decline with an unreadable checkpoint write never suspends
    and never schedules a wake; the terminal checkpoint (distinct id,
    healthy lookup) still preserves recovery context.
  - `lease_not_renewable` boundary twin with the same injection stays
    bounded: no suspend, no wake, safe stop requested, terminal arrives,
    and the next boundary retries into a recovered reactive checkpoint.
  - Planned boundary decline persists an evidence-backed reactive
    checkpoint (kind `reactive`, lease stop reason, goal/task acceptance
    contract with descriptions, deterministic next step) before
    suspend + sleep wake.
  - Full repository-evidence reactive path (fixture worktree): revision,
    dirty diff, changed files, verification lines, and boundary are real.
  - Terminal twins (completed / failed) carry the goal/task acceptance
    contract with descriptions.

  Locking note (standing contract): on the pre-fix base commit the
  reactive writer has no `reactive` kind and the decline suspends even
  when the checkpoint write fails, so the kind/count/no-suspend/no-wake
  assertions below fail behaviourally there; the terminal checkpoint
  exists on base but carries the generic criterion, so the acceptance
  assertions fail there too. This file references only base-present
  modules. The no-extension fresh-start prompt pin passes on base as
  well (documentation, stated honestly).
  """

  use Shoestring.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Shoestring.Cobbler.{Leases, WakeupRecord}
  alias Shoestring.Elves
  alias Shoestring.Elves.PoisonCheckpointRepo
  alias Shoestring.Harness.{CapacitySnapshot, ExecutionLease, ExecutionLeaseRecord, Projector}
  alias Shoestring.Harness.Fake.Scenario
  alias Shoestring.Repo
  alias Shoestring.Test.CobblerHelpers
  alias Shoestring.Test.ElfWorktreeFixture
  alias Shoestring.Test.ElvesHelpers
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Test.FixedClock
  alias Shoestring.Trajectory.TrajectoryEvent

  @runner_opts [kill_grace_ms: 200, reap_timeout_ms: 2_000]
  @interval_ms 200
  @session_table :codex_app_server_sessions

  setup do
    sup = start_supervised!({Shoestring.Elves.Supervisor, name: nil})
    %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()

    goal =
      goal
      |> Shoestring.Trajectory.Goal.changeset(%{
        "description" => "Deterministic acceptance description for the goal."
      })
      |> Repo.update!()

    task =
      task
      |> Shoestring.Trajectory.Task.changeset(%{
        "description" => "Deterministic acceptance description for the task."
      })
      |> Repo.update!()

    {:ok, sup: sup, goal: goal, task: task}
  end

  test "quota-path decline with unreadable checkpoint write never suspends or wakes", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    # The checkpoint write fails twice (full attempt + floor retry hit the
    # poisoned replay); the decline must not suspend, settle, or schedule
    # a wake — but still asks the live session to stop at its next safe
    # boundary. The terminal checkpoint (distinct id, healthy lookup)
    # still lands, preserving recovery context.
    # (Base: the failed write is swallowed and the run suspends + wakes
    # with no checkpoint persisted.)
    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id, used_percent: 95.0)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    quota_error =
      Shoestring.Harness.Error.new(
        :quota_refused,
        "rate_limit_exceeded",
        "subscription limit reached"
      )

    scenario =
      fake_scenario(:poison_quota_decline, breached_snapshot(fresh_id), [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        Scenario.output_event("partial work", source_event_id: "evt-out-1"),
        Scenario.error_event(quota_error, source_event_id: "evt-quota")
      ])

    request = ElvesHelpers.run_request(goal, task)

    log =
      capture_log(fn ->
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
          response_budget: 10,
          tool_budget: 25,
          reserves: %{response: 1, tool: 1},
          checkpoint_cadence: 100,
          deadline: DateTime.add(FixedClock.now(), 3_600, :second)
        )

        start_gate(2)
        swap_repo(elf_pid)
        register_session_double(request.dispatch_id)

        assert_receive {:elf_terminal, ^run_id, _terminal}, 15_000
        send(self(), {:run_done, run_id})
      end)

    assert_received {:run_done, run_id}

    # No suspension or wake without a persisted structural checkpoint…
    assert count_types(goal.id, run_id, ["run.pausing"]) == 0
    assert count_types(goal.id, run_id, ["run.suspended"]) == 0
    assert Repo.get_by(WakeupRecord, run_id: run_id) == nil
    assert reactive_checkpoints(goal.id, run_id) == []

    # …but bounded execution (safe stop asked) and durable recovery (the
    # terminal checkpoint landed with the acceptance contract).
    assert_received :safe_stop_requested
    assert log =~ "stays active for retry"

    [terminal] = terminal_checkpoints(goal.id, run_id)
    criteria = Enum.join(terminal.payload["acceptance_contract"]["criteria"], "\n")
    assert criteria =~ "Elf goal"
    assert criteria =~ "Deterministic acceptance description for the goal."
    assert criteria =~ "Elf task"
    assert criteria =~ "Deterministic acceptance description for the task."
  end

  test "lease_not_renewable boundary with unreadable write stays bounded and recovers", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    # The lease is already terminal (expired) when the boundary fires, so
    # the renewal layer reports not-renewable. The first write fails twice
    # (poisoned replay); the run must not settle quietly — the next
    # boundary retries into a recovered checkpoint — and must not suspend
    # or wake without one. A safe stop is still requested.
    # (Base: the failed write is swallowed AND settled, so no boundary
    # ever retries and no reactive checkpoint ever appears.)
    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id, used_percent: 95.0)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    scenario =
      fake_scenario(:poison_not_renewable, breached_snapshot(fresh_id), [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        Scenario.output_event("one", source_event_id: "evt-out-1"),
        Scenario.output_event("two", source_event_id: "evt-out-2"),
        Scenario.output_event("three", source_event_id: "evt-out-3"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    request = ElvesHelpers.run_request(goal, task)

    log =
      capture_log(fn ->
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

        %{grant_id: grant_id} =
          grant_for_run!(goal, run_id, fresh_id,
            response_budget: 2,
            tool_budget: 25,
            reserves: %{response: 0, tool: 0},
            checkpoint_cadence: 100,
            deadline: DateTime.add(FixedClock.now(), 3_600, :second)
          )

        assert {:ok, _} = Leases.transition(goal.id, grant_id, :expire)
        assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

        start_gate(2)
        swap_repo(elf_pid)
        register_session_double(request.dispatch_id)

        assert_receive {:elf_terminal, ^run_id, %{class: :completed}}, 15_000
        send(self(), {:run_done, run_id})
      end)

    assert_received {:run_done, run_id}

    # Recovered on retry: exactly one reactive checkpoint, never preceded
    # by a suspension or a wake without contents.
    assert length(reactive_checkpoints(goal.id, run_id)) == 1
    assert count_types(goal.id, run_id, ["run.suspended"]) == 0
    assert Repo.get_by(WakeupRecord, run_id: run_id) == nil

    assert_received :safe_stop_requested
    assert log =~ "retry left open"
  end

  test "planned boundary decline persists an evidence-backed reactive checkpoint", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id, used_percent: 95.0)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    scenario =
      fake_scenario(:reactive_decline, breached_snapshot(fresh_id), [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        Scenario.output_event("one", source_event_id: "evt-out-1"),
        Scenario.output_event("two", source_event_id: "evt-out-2"),
        Scenario.output_event("three", source_event_id: "evt-out-3"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    request = ElvesHelpers.run_request(goal, task)

    assert {:ok, _pid} =
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

    assert_receive {:elf_terminal, ^run_id, _terminal}, 15_000

    # One reactive checkpoint (kind "reactive", never "terminal"), then the
    # durable sleep shape. (Base: no `reactive` kind is ever emitted.)
    [checkpoint] = reactive_checkpoints(goal.id, run_id)
    payload = checkpoint.payload

    assert payload["stop_reason"] == "lease_exhausted"
    assert payload["extensions"]["shoestring.elf:checkpoint_kind"] == "reactive"

    criteria = Enum.join(payload["acceptance_contract"]["criteria"], "\n")
    assert criteria =~ "Elf goal"
    assert criteria =~ "Deterministic acceptance description for the goal."
    assert criteria =~ "Elf task"
    assert criteria =~ "Deterministic acceptance description for the task."

    assert payload["next_action"] =~ "mix precommit"
    assert payload["next_action"] =~ "lease_exhausted"

    assert count_types(goal.id, run_id, ["run.suspended"]) == 1
    assert Repo.get_by!(WakeupRecord, run_id: run_id).status == "scheduled"
  end

  test "reactive decline through a fixture worktree carries full repository evidence", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    # The full collector path (not the floor): worktree identity, current
    # revision, dirty diff stat, changed-file list, verification lines,
    # and last safe boundary are all real. (Base: generic criterion with
    # no `reactive` kind and revision "unknown".)
    run_id = Ecto.UUID.generate()
    fixture = ElfWorktreeFixture.create!(run_id)
    on_exit(fn -> ElfWorktreeFixture.cleanup!(fixture) end)

    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id, used_percent: 95.0)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    scenario =
      fake_scenario(:reactive_full_evidence, breached_snapshot(fresh_id), [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        command_event(source_event_id: "cmd-verify-1"),
        Scenario.output_event("one", source_event_id: "evt-out-1"),
        Scenario.output_event("two", source_event_id: "evt-out-2"),
        Scenario.output_event("three", source_event_id: "evt-out-3"),
        Scenario.result_event("completed", source_event_id: "evt-done")
      ])

    request =
      ElvesHelpers.run_request(goal, task,
        workspace_ref: fixture.worktree.workspace_ref,
        dispatch_id: Ecto.UUID.generate()
      )

    child_script = """
    from pathlib import Path

    if Path("fixture.txt").exists():
        Path("fixture.txt").write_text("fixture baseline\\nreactive checkpoint edit\\n")
        Path("reactive-evidence-note.txt").write_text("written by the Elf child\\n")
        import time
        time.sleep(30)
    """

    assert {:ok, _pid} =
             Elves.start_run(request, ElvesHelpers.fake_identity(),
               supervisor: sup,
               run_id: run_id,
               scenario: scenario,
               command: ["python3", "-c", child_script],
               runner_opts: @runner_opts,
               clock: FixedClock,
               event_interval_ms: @interval_ms,
               notify: self()
             )

    on_exit(fn -> ElvesHelpers.cleanup_group(ElvesHelpers.recorded_pgid(goal.id, run_id)) end)

    grant_for_run!(goal, run_id, fresh_id,
      response_budget: 2,
      tool_budget: 25,
      reserves: %{response: 0, tool: 0},
      checkpoint_cadence: 100,
      deadline: DateTime.add(FixedClock.now(), 3_600, :second)
    )

    assert_receive {:elf_terminal, ^run_id, _terminal}, 15_000

    [checkpoint] = reactive_checkpoints(goal.id, run_id)
    payload = checkpoint.payload

    assert payload["repository_state"]["revision"] == fixture.base_commit
    assert payload["repository_state"]["dirty"] == true
    assert payload["extensions"]["shoestring.elf:checkpoint_kind"] == "reactive"

    evidence = Enum.join(payload["evidence"]["items"], "\n")
    assert evidence =~ fixture.base_commit
    assert evidence =~ "reactive-evidence-note.txt"
    assert evidence =~ "fixture.txt"
    assert evidence =~ "diff stat"
    assert evidence =~ "command cmd-verify-1"
    assert evidence =~ "last safe boundary"
    assert evidence =~ "lease_exhausted"
  end

  test "terminal twins carry the goal/task acceptance contract with descriptions", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    # The terminal checkpoint exists on base too — the lock is the
    # acceptance contract naming the durable goal/task (titles and
    # descriptions) instead of the generic placeholder.
    for {name, result} <- [completed_twin: "completed", failed_twin: "failed"] do
      run_id = Ecto.UUID.generate()

      scenario =
        ElvesHelpers.custom_scenario(name, [
          Scenario.lifecycle_event(source_event_id: "evt-life-#{name}"),
          Scenario.result_event(result, source_event_id: "evt-done-#{name}")
        ])

      request = ElvesHelpers.run_request(goal, task, dispatch_id: Ecto.UUID.generate())

      assert {:ok, _pid} =
               Elves.start_run(request, ElvesHelpers.fake_identity(),
                 supervisor: sup,
                 run_id: run_id,
                 scenario: scenario,
                 command: ["sleep", "30"],
                 runner_opts: @runner_opts,
                 event_interval_ms: @interval_ms,
                 notify: self()
               )

      assert_receive {:elf_terminal, ^run_id, _terminal}, 15_000

      [checkpoint] = terminal_checkpoints(goal.id, run_id)
      criteria = Enum.join(checkpoint.payload["acceptance_contract"]["criteria"], "\n")
      assert criteria =~ "Elf goal"
      assert criteria =~ "Deterministic acceptance description for the goal."
      assert criteria =~ "Elf task"
      assert criteria =~ "Deterministic acceptance description for the task."
    end
  end

  # -- Helpers --

  defp command_event(opts) do
    %{
      kind: :command,
      offset_ms: Keyword.get(opts, :offset_ms, 0),
      source_event_id: Keyword.fetch!(opts, :source_event_id),
      error: nil,
      result: nil,
      capacity_snapshot: nil,
      extensions: %{"shoestring.fake:detail" => "verify"}
    }
  end

  defp wait_running(goal, dispatch_id) do
    assert {:ok, run_id} =
             ElvesHelpers.wait_until(fn -> ElvesHelpers.run_id_for_dispatch(dispatch_id) end)

    assert {:ok, _pgid} =
             ElvesHelpers.wait_until(fn -> ElvesHelpers.recorded_pgid(goal.id, run_id) end)

    run_id
  end

  # Starts the poison gate: the next `count` checkpoint idempotency
  # lookups fail the replay rebuild; later ones delegate (recovery).
  defp start_gate(count) do
    {:ok, _pid} = Agent.start_link(fn -> count end, name: :poison_checkpoint_gate)

    on_exit(fn ->
      if pid = Process.whereis(:poison_checkpoint_gate) do
        if Process.alive?(pid), do: Agent.stop(pid)
      end
    end)

    :ok
  end

  # Points a live Elf at the poison wrapper after its run intent is
  # durable. Pre-decline behavior is identical under the wrapper (full
  # delegation), so the swap is race-free by construction.
  defp swap_repo(elf_pid) do
    :sys.replace_state(elf_pid, fn state -> %{state | repo: PoisonCheckpointRepo} end)
    :ok
  end

  # Registers a live session double for `id` in the Codex session table:
  # answers `request_safe_stop` and notifies the test. Hermetic and
  # deterministic; cleaned up on exit.
  defp register_session_double(id) do
    _ = Shoestring.Harness.CodexAppServer.lookup_session(Ecto.UUID.generate())

    test = self()
    double = spawn(fn -> session_double_loop(test) end)

    :ets.insert(@session_table, {id, double})

    on_exit(fn ->
      if :ets.info(@session_table) != :undefined do
        :ets.delete(@session_table, id)
      end

      if Process.alive?(double), do: Process.exit(double, :kill)
    end)

    :ok
  end

  defp session_double_loop(test) do
    receive do
      {:"$gen_call", {caller, ref}, :request_safe_stop} ->
        send(test, :safe_stop_requested)
        send(caller, {ref, {:ok, :stop_requested}})
        session_double_loop(test)
    end
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
          "explanation" => "Elf checkpoint resume test admission",
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

  defp checkpoint_events(goal_id, run_id) do
    Repo.all(
      from event in TrajectoryEvent,
        where:
          event.goal_id == ^goal_id and event.run_id == ^run_id and
            event.type == "checkpoint.created",
        order_by: [asc: event.sequence]
    )
  end

  defp reactive_checkpoints(goal_id, run_id) do
    checkpoint_events(goal_id, run_id)
    |> Enum.filter(fn event ->
      event.payload["extensions"]["shoestring.elf:checkpoint_kind"] == "reactive"
    end)
  end

  defp terminal_checkpoints(goal_id, run_id) do
    checkpoint_events(goal_id, run_id)
    |> Enum.filter(fn event ->
      event.payload["extensions"]["shoestring.elf:checkpoint_kind"] == "terminal"
    end)
  end
end
