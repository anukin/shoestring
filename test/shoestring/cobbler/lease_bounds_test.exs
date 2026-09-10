defmodule Shoestring.Cobbler.LeaseBoundsTest do
  @moduledoc """
  Hermetic tests for execution-lease bound advancement: Fake-scripted event
  sequences drive the pure counter (output completions spend responses, tool
  and command completions spend tools, delta/START/lifecycle frames never
  spend), Claude `:task_failed` errors spend nothing and never signal quota,
  Codex `:quota_refused` signals immediately with zero spend, renewal-due
  fires one reserve early, and fresh-renew vs refused-expire settle through
  the renewal path.

  Locking note (standing contract): every test below exercises the new
  `LeaseBounds`/`LeaseRenewal` modules (or the dispatcher lease hook), so on
  the pre-fix commit they error on the missing modules rather than failing
  behaviourally. They are documentation of the new surface — except where a
  Fake sequence pins provider mapping semantics that predate this slice
  (noted inline) — and are labeled honestly as such.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Cobbler.{Dispatcher, LeaseBounds, LeaseRenewal}

  alias Shoestring.Harness.{
    CapacitySnapshot,
    Error,
    ExecutionLease,
    ExecutionLeaseRecord,
    Fake,
    HarnessEvent,
    Projector
  }

  alias Shoestring.Harness.Fake.Scenario
  alias Shoestring.Test.FixedClock

  import Shoestring.Test.CobblerHelpers
  alias Shoestring.Test.Fixtures.FakeHelpers

  @now ~U[2026-09-07 12:00:00.000000Z]
  @run_id "01950000-0000-7000-8000-000000000001"
  @grant_id "01950000-0000-7000-8000-000000000002"
  @snapshot_id "01950000-0000-7000-8000-000000000003"
  @quota_run_id "01950000-0000-7000-8000-000000000004"

  # ----------------------------------------------------------------------------
  # Bound advancement over Fake sequences
  # ----------------------------------------------------------------------------

  test "Fake normal completion spends one response per output, nothing else" do
    state = bounds()
    identity = fake_identity()

    {:ok, events} =
      Fake.stream(identity, %{scenario: Scenario.normal_completion(), clock: FixedClock})

    # normal_completion: lifecycle, output, output, result.
    assert Enum.map(events, & &1.kind) == [:lifecycle, :output, :output, :result]

    {state, effects} = LeaseBounds.drain(state, identity.run_id, events)

    assert state.responses == 2
    assert state.tools == 0
    assert effects == []
    refute state.due
  end

  test "delta frames never spend" do
    state = bounds()

    delta =
      event(:output, 1, %{
        "codex-app-server:method" => "item/agentMessage/delta",
        "codex-app-server:delta" => "I"
      })

    bare_delta = event(:output, 2, %{"codex-app-server:method" => "item/agentMessage/delta"})

    {state, []} = LeaseBounds.advance(state, delta)
    {state, []} = LeaseBounds.advance(state, bare_delta)

    assert state.responses == 0
  end

  test "Codex item/started agentMessages never spend; completions spend one" do
    state = bounds()

    started =
      event(:output, 1, %{
        "codex-app-server:item_id" => "item-1",
        "codex-app-server:phase" => "commentary"
      })

    completed =
      event(:output, 2, %{
        "codex-app-server:item_id" => "item-1",
        "codex-app-server:phase" => "final_answer",
        "codex-app-server:text" => "done"
      })

    {state, []} = LeaseBounds.advance(state, started)
    assert state.responses == 0
    {state, []} = LeaseBounds.advance(state, completed)
    assert state.responses == 1
  end

  test "tool events and command START→END completions spend exactly once" do
    state = bounds()

    start =
      event(:command, 1, %{
        "codex-app-server:item_id" => "cmd-1",
        "codex-app-server:status" => "inProgress"
      })

    finish =
      event(:command, 2, %{
        "codex-app-server:item_id" => "cmd-1",
        "codex-app-server:status" => "completed",
        "codex-app-server:exit_code" => 0
      })

    tool = event(:tool, 3, %{"codex-app-server:tool" => "fileChange"})

    {state, []} = LeaseBounds.advance(state, start)
    assert state.tools == 0

    {state, []} = LeaseBounds.advance(state, finish)
    assert state.tools == 1

    # A redelivered END never double-spends.
    {state, []} = LeaseBounds.advance(state, finish)
    assert state.tools == 1

    {state, []} = LeaseBounds.advance(state, tool)
    assert state.tools == 2
  end

  test "Claude tool_use START→tool_result END correlates by toolu id only" do
    state = bounds()

    start =
      event(:command, 1, %{
        "claude-headless:boundary" => "start",
        "claude-headless:tool_use_id" => "toolu_1"
      })

    finish =
      event(:command, 2, %{
        "claude-headless:boundary" => "end",
        "claude-headless:tool_use_id" => "toolu_1"
      })

    {state, []} = LeaseBounds.advance(state, start)
    assert state.tools == 0
    {state, []} = LeaseBounds.advance(state, finish)
    assert state.tools == 1
  end

  test "lifecycle, capacity, result, and non-quota error events never spend" do
    state = bounds()

    events = [
      event(:lifecycle, 1, %{"codex-app-server:method" => "turn/started"}),
      event(:capacity, 2, %{}, capacity_snapshot_id: @snapshot_id),
      event(:result, 3, %{}, result: %{"status" => "completed"}),
      error_event(4, Error.new(:task_failed, "turn_failed", "Claude headless error"))
    ]

    {state, effects} =
      Enum.reduce(events, {state, []}, fn e, {s, _} -> LeaseBounds.advance(s, e) end)

    assert state.responses == 0
    assert state.tools == 0
    assert effects == []
    refute state.quota_refused
  end

  test "Claude errors map to task_failed and never to quota_refused" do
    # Pins the standing Gate 0A rule through the bounds lens: a Claude-style
    # failure spends nothing and raises no quota fast path.
    state = bounds()

    claude_error =
      error_event(1, Error.new(:task_failed, "claude_error", "is_error true, subtype success"))

    {state, effects} = LeaseBounds.advance(state, claude_error)

    assert effects == []
    assert state.responses == 0
    assert state.tools == 0
    refute state.quota_refused
  end

  test "Codex quota_refused signals immediately with zero spend" do
    state = bounds()
    identity = fake_identity()

    {:ok, events} =
      Fake.stream(identity, %{scenario: Scenario.sudden_quota_refusal(), clock: FixedClock})

    # sudden_quota_refusal: lifecycle, output (partial work), quota error.
    assert Enum.any?(events, &(&1.kind == :error and &1.error.category == :quota_refused))

    {state, effects} = LeaseBounds.drain(state, identity.run_id, events)

    assert :quota_refused in effects
    assert state.quota_refused
    # The partial-work output spent one response; the quota error spent zero.
    assert state.responses == 1
    assert state.tools == 0
  end

  test "renewal-due fires one reserve early on each budget axis" do
    state = bounds(%{checkpoint_cadence: 1_000})

    state =
      Enum.reduce(1..8, state, fn n, s ->
        {s, effects} = LeaseBounds.advance(s, output(n))
        assert effects == []
        s
      end)

    assert state.responses == 8
    refute LeaseBounds.due?(state)

    {state, effects} = LeaseBounds.advance(state, output(9))
    assert effects == [:renewal_due]
    assert state.due

    # Edge-triggered: staying due emits no repeat marker.
    {_state, effects} = LeaseBounds.advance(state, output(10))
    assert effects == []

    tools = bounds(%{checkpoint_cadence: 1_000})

    tools =
      Enum.reduce(1..23, tools, fn n, s ->
        {s, effects} = LeaseBounds.advance(s, event(:tool, n, %{}))
        assert effects == []
        s
      end)

    {_tools, effects} = LeaseBounds.advance(tools, event(:tool, 24, %{}))
    assert effects == [:renewal_due]
  end

  test "checkpoint cadence reached fires due" do
    state = bounds(%{checkpoint_cadence: 2, response_budget: 100, tool_budget: 100})

    {state, []} = LeaseBounds.advance(state, output(1))
    refute LeaseBounds.due?(state)

    {_state, effects} = LeaseBounds.advance(state, output(2))
    assert effects == [:renewal_due]
  end

  test "drain ignores other runs and redeliveries" do
    state = bounds()
    other = %{output(1) | run_id: "01950000-0000-7000-8000-000000000099"}

    {state, _} = LeaseBounds.drain(state, @run_id, [output(1), other, output(1)])
    assert state.responses == 1
  end

  # ----------------------------------------------------------------------------
  # Fresh-renew vs refused-expire through the renewal path
  # ----------------------------------------------------------------------------

  test "Codex quota blocks renewal: refused re-evaluation expires the lease" do
    %{goal: goal, grant_id: grant_id} = granted_lease()

    # The live buffer saw the quota fast path with zero tool spend.
    {bounds_state, effects} =
      LeaseBounds.drain(bounds_for(grant_id), @quota_run_id, quota_events())

    assert :quota_refused in effects
    assert bounds_state.tools == 0

    breached_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, breached_id)

    assert {:ok, %{outcome: :expired, reason: "reserve_breach_five_hour"}} =
             LeaseRenewal.handle_quota_refusal(goal.id, grant_id,
               now: @now,
               observe: fn -> {:ok, breached_snapshot(breached_id)} end
             )

    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)
    assert Repo.get!(ExecutionLeaseRecord, grant_id).status == "checkpoint_required"
  end

  test "fresh-renew chains the new admitted snapshot id" do
    %{goal: goal, grant_id: grant_id, snapshot_id: snapshot_id} = granted_lease()

    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    assert {:ok, %{outcome: :renewed, admitted_snapshot_id: ^fresh_id}} =
             LeaseRenewal.maybe_renew(goal.id, grant_id,
               now: @now,
               stop: :already_requested,
               boundary: :item_completed,
               observe: fn -> {:ok, fresh_snapshot(fresh_id)} end
             )

    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)
    record = Repo.get!(ExecutionLeaseRecord, grant_id)
    assert record.status == "renewed"
    assert record.admitted_snapshot_id == fresh_id
    assert record.admitted_snapshot_id != snapshot_id
  end

  test "refused-expire appends expired before checkpoint_required" do
    %{goal: goal, grant_id: grant_id} = granted_lease()

    breached_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, breached_id)

    assert {:ok, %{outcome: :expired, events: [expired, checkpoint]}} =
             LeaseRenewal.maybe_renew(goal.id, grant_id,
               now: @now,
               stop: :already_requested,
               boundary: :item_completed,
               observe: fn -> {:ok, breached_snapshot(breached_id)} end
             )

    assert expired.type == "lease.expired"
    assert checkpoint.type == "lease.checkpoint_required"
    assert expired.sequence < checkpoint.sequence

    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)
    assert Repo.get!(ExecutionLeaseRecord, grant_id).status == "checkpoint_required"
  end

  # ----------------------------------------------------------------------------
  # New spend epoch after a renewal (lease re-loop P1)
  #
  # Locking note: `LeaseBounds.new_epoch/1` does not exist on the base
  # commit, so these tests error there with `UndefinedFunctionError` —
  # documentation of the new surface, not behavior-change locks.
  # ----------------------------------------------------------------------------

  test "new_epoch resets spend and the due latch, keeping identity and seen" do
    state = bounds()
    assert state.epoch == 0

    events = Enum.map(1..9, &output/1)
    {state, effects} = LeaseBounds.drain(state, @run_id, events)

    # response_budget 10, reserve 1 → due at the 9th completion.
    assert state.responses == 9
    assert state.due == true
    assert :renewal_due in effects

    renewed = LeaseBounds.new_epoch(state)

    assert renewed.epoch == 1
    assert renewed.responses == 0
    assert renewed.tools == 0
    assert renewed.due == false
    assert renewed.quota_refused == false
    assert renewed.grant_id == state.grant_id
    assert renewed.run_id == state.run_id
    assert renewed.response_budget == state.response_budget
    assert renewed.tool_budget == state.tool_budget

    # Already-counted events never double-spend across the epoch boundary.
    {replayed, replay_effects} = LeaseBounds.drain(renewed, @run_id, events)
    assert replayed.responses == 0
    assert replay_effects == []

    # Fresh spend re-fires the edge-triggered due exactly once.
    fresh = Enum.map(1..9, &output(100 + &1))
    {epoch2, epoch2_effects} = LeaseBounds.drain(replayed, @run_id, fresh)

    assert epoch2.responses == 9
    assert epoch2.due == true
    assert :renewal_due in epoch2_effects
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  defp bounds(overrides \\ %{}) do
    attrs =
      %{
        version: 1,
        grant_id: @grant_id,
        run_id: @run_id,
        admitted_snapshot_id: @snapshot_id,
        reserves: %{response: 1, tool: 1},
        response_budget: 10,
        tool_budget: 25,
        deadline: DateTime.add(@now, 300, :second),
        checkpoint_cadence: 100,
        renewal_state: :none,
        extensions: %{}
      }
      |> Map.merge(overrides)

    {:ok, lease} = ExecutionLease.new(attrs)
    LeaseBounds.new(lease)
  end

  defp bounds_for(_grant_id), do: bounds(%{run_id: @quota_run_id})

  defp fake_identity do
    %Shoestring.Harness.RunIdentity{
      run_id: Ecto.UUID.generate(),
      harness_id: "shoestring.harness.fake",
      process_id: "fake-pid-test",
      provider_session_id: "fake-session-test"
    }
  end

  defp quota_events do
    identity = %Shoestring.Harness.RunIdentity{
      run_id: @quota_run_id,
      harness_id: "shoestring.harness.fake",
      process_id: "fake-pid-test",
      provider_session_id: "fake-session-test"
    }

    {:ok, events} =
      Fake.stream(identity, %{scenario: Scenario.sudden_quota_refusal(), clock: FixedClock})

    events
  end

  defp output(n), do: event(:output, n, %{"shoestring.fake:text" => "response #{n}"})

  defp event(kind, n, extensions, extra \\ []) do
    attrs =
      [
        version: 1,
        run_id: @run_id,
        source_event_id: "evt-#{n}-#{kind}",
        ordinal: n,
        occurred_at: @now,
        kind: kind,
        extensions: extensions
      ] ++ extra

    {:ok, event} = HarnessEvent.new(Map.new(attrs))
    event
  end

  defp error_event(n, %Error{} = error) do
    {:ok, event} =
      HarnessEvent.new(%{
        version: 1,
        run_id: @run_id,
        source_event_id: "evt-#{n}-error",
        ordinal: n,
        occurred_at: @now,
        kind: :error,
        error: error,
        extensions: %{}
      })

    event
  end

  defp fresh_snapshot(snapshot_id) do
    {:ok, snapshot} =
      CapacitySnapshot.new(
        %{
          version: 2,
          snapshot_id: snapshot_id,
          capacity_state: :observed,
          windows: [
            %{kind: "five_hour", state: :observed, used_percent: 20.0, reset_at: nil},
            %{kind: "weekly", state: :observed, used_percent: 30.0, reset_at: nil}
          ],
          observed_at: @now,
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
        now: @now
      )

    snapshot
  end

  defp breached_snapshot(snapshot_id) do
    {:ok, snapshot} =
      CapacitySnapshot.new(
        %{
          version: 2,
          snapshot_id: snapshot_id,
          capacity_state: :observed,
          windows: [
            %{kind: "five_hour", state: :observed, used_percent: 95.0, reset_at: nil},
            %{kind: "weekly", state: :observed, used_percent: 30.0, reset_at: nil}
          ],
          observed_at: @now,
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
        now: @now
      )

    snapshot
  end

  defp granted_lease do
    goal = create_goal!()
    task = insert_task!(goal)
    snapshot_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, snapshot_id)

    admission = append_admission_event!(goal.id, grant_payload(snapshot_id))

    command =
      claim_command(admission, command_id: "cmd-bounds-#{System.unique_integer([:positive])}")

    assert {:ok, leased} =
             Dispatcher.claim_and_gate(goal.id, command,
               now: @now,
               grant_lease: [task_id: task.id, clock: FixedClock, now: FixedClock.now()]
             )

    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    %{
      goal: goal,
      task: task,
      snapshot_id: snapshot_id,
      grant_id: leased.grant_id,
      run_id: leased.run.id
    }
  end

  defp insert_task!(goal) do
    %Shoestring.Trajectory.Task{}
    |> Shoestring.Trajectory.Task.changeset(%{"title" => "Lease bounds task"})
    |> Ecto.Changeset.put_change(:goal_id, goal.id)
    |> Repo.insert!()
  end

  defp grant_payload(snapshot_id) do
    admission_payload()
    |> Map.merge(%{
      "result" => "admit",
      "reason_code" => "automatic_admission_eligible",
      "explanation" => "Lease bounds test admission",
      "observation" => %{
        "snapshot_id" => snapshot_id,
        "confidence" => "high",
        "freshness" => "fresh"
      },
      "proposed_bounds" => %{
        "response_budget" => 10,
        "tool_budget" => 25,
        "deadline" => DateTime.to_iso8601(DateTime.add(@now, 300, :second)),
        "checkpoint_cadence" => 100,
        "reserves" => %{"response" => 1, "tool" => 1}
      }
    })
  end
end
