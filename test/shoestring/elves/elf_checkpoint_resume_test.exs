defmodule Shoestring.Elves.ElfCheckpointResumeTest do
  @moduledoc """
  Hermetic Elf tests for reliable iteration-5 checkpoints and
  same-provider continuation (finding: checkpoint/resume round).

  - Planned boundary decline persists an evidence-backed reactive
    checkpoint (goal/task acceptance contract, lease stop reason,
    deterministic next step) before suspend + sleep wake.
  - Quota-refusal decline is the twin: same reactive shape through the
    fast path.
  - Checkpoint persistence failure never suspends and never schedules a
    wake: the run stays active so the next boundary retries, and no wake
    continuation can run without a persisted structural checkpoint.
  - Terminal twins (completed / failed) carry the goal acceptance
    contract in their checkpoints.

  Locking note (standing contract): on the pre-fix base commit
  (`6fd0ecd`) the reactive writer hardcodes a generic criterion and
  `"unknown"` revision with no `reactive` kind, and the decline path
  suspends even when the checkpoint write fails — so the acceptance,
  kind, and no-suspend assertions below fail behaviourally there. The
  terminal-twin test fails on base with zero `checkpoint.created`
  events. This file references only base-present modules.
  """

  use Shoestring.DataCase, async: false

  import Ecto.Query

  alias Shoestring.Cobbler.{Leases, WakeupRecord}
  alias Shoestring.Elves
  alias Shoestring.Harness.{CapacitySnapshot, ExecutionLease, ExecutionLeaseRecord, Projector}
  alias Shoestring.Harness.Fake.Scenario
  alias Shoestring.Repo
  alias Shoestring.Test.CobblerHelpers
  alias Shoestring.Test.ElvesHelpers
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Test.FixedClock
  alias Shoestring.Trajectory.TrajectoryEvent

  @runner_opts [kill_grace_ms: 200, reap_timeout_ms: 2_000]
  @interval_ms 200

  setup do
    sup = start_supervised!({Shoestring.Elves.Supervisor, name: nil})
    %{goal: goal, task: task} = ElvesHelpers.insert_goal_task()
    {:ok, sup: sup, goal: goal, task: task}
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
    # durable sleep shape. (Base: generic criterion without the goal title,
    # no reactive kind, revision "unknown" with no lease context.)
    [checkpoint] = reactive_checkpoints(goal.id, run_id)
    payload = checkpoint.payload

    assert payload["stop_reason"] == "lease_exhausted"
    assert payload["extensions"]["shoestring.elf:checkpoint_kind"] == "reactive"

    criteria = Enum.join(payload["acceptance_contract"]["criteria"], "\n")
    assert criteria =~ "Elf goal"
    assert criteria =~ "Elf task"
    refute criteria == "complete the supervised task per the goal acceptance contract"

    assert payload["next_action"] =~ "mix precommit"
    assert payload["next_action"] =~ "lease_exhausted"

    assert count_types(goal.id, run_id, ["run.suspended"]) == 1
    assert Repo.get_by!(WakeupRecord, run_id: run_id).status == "scheduled"
  end

  test "quota-refusal decline is the reactive twin through the fast path", %{
    sup: sup,
    goal: goal,
    task: task
  } do
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
      fake_scenario(:reactive_quota, breached_snapshot(fresh_id), [
        Scenario.lifecycle_event(source_event_id: "evt-life"),
        Scenario.output_event("partial work", source_event_id: "evt-out-1"),
        Scenario.error_event(quota_error, source_event_id: "evt-quota")
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
      response_budget: 10,
      tool_budget: 25,
      reserves: %{response: 1, tool: 1},
      checkpoint_cadence: 100,
      deadline: DateTime.add(FixedClock.now(), 3_600, :second)
    )

    assert_receive {:elf_terminal, ^run_id, _terminal}, 15_000

    [checkpoint] = reactive_checkpoints(goal.id, run_id)
    payload = checkpoint.payload

    assert payload["stop_reason"] == "lease_exhausted"
    assert payload["extensions"]["shoestring.elf:checkpoint_kind"] == "reactive"

    criteria = Enum.join(payload["acceptance_contract"]["criteria"], "\n")
    assert criteria =~ "Elf goal"

    assert count_types(goal.id, run_id, ["run.suspended"]) == 1
    assert Repo.get_by!(WakeupRecord, run_id: run_id).status == "scheduled"
  end

  test "checkpoint persistence failure never suspends and never schedules a wake", %{
    sup: sup,
    goal: goal,
    task: task
  } do
    # Failing writer seam for both the full and floor attempts: the
    # decline must leave the run active (no suspend, no wake) so the next
    # boundary retries instead of sleeping without recovery context.
    # (Base: the decline suspends + wakes even when the write fails.)
    failing = fn _goal_id, _checkpoint, _opts -> {:error, :boom} end
    Application.put_env(:shoestring, :terminal_checkpoint_writer, failing)

    on_exit(fn -> Application.delete_env(:shoestring, :terminal_checkpoint_writer) end)

    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id, used_percent: 95.0)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    scenario =
      fake_scenario(:reactive_write_fails, breached_snapshot(fresh_id), [
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

    # The run still terminates normally (nothing was interrupted mid-item
    # and the group lifecycle is untouched), but with zero checkpoint
    # contents, zero suspend events, and no sleep wake to continue from.
    assert_receive {:elf_terminal, ^run_id, %{class: :completed}}, 15_000

    assert checkpoint_events(goal.id, run_id) == []
    assert count_types(goal.id, run_id, ["run.pausing"]) == 0
    assert count_types(goal.id, run_id, ["run.suspended"]) == 0
    assert Repo.get_by(WakeupRecord, run_id: run_id) == nil
  end

  test "terminal twins carry the goal acceptance contract", %{sup: sup, goal: goal, task: task} do
    # Completed twin: the terminal checkpoint's acceptance contract names
    # the durable goal/task instead of the generic placeholder. (Base:
    # no checkpoint.created event at all.)
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
      assert criteria =~ "Elf task"
    end
  end

  # -- Helpers --

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
