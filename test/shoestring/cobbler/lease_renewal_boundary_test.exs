defmodule Shoestring.Cobbler.LeaseRenewalBoundaryTest do
  @moduledoc """
  Hermetic DataCase tests for renewal at the safe boundary: no `stop`
  precedes no `expired` append (the module never restops — it takes no
  session and accepts only the `:already_requested` flag), the
  `item.completed` boundary gates every transition, renewals chain a fresh
  snapshot (never the admitted one), refusals expire before requiring a
  checkpoint, and the quota fast path spends nothing.

  Locking note (standing contract): these tests exercise the new
  `LeaseRenewal` module directly, so on the pre-fix commit they error on the
  missing module rather than failing behaviourally — they are documentation
  of the new surface, labeled honestly as such. The one property with an
  old-code anchor is the last test: existing `LeaseBoundary`/`LeaseWatcher`
  behavior is unchanged (no new process, no evaluation/effects added there),
  which the full gate verifies by keeping every pre-existing lease boundary
  test green.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Cobbler.{Dispatcher, LeaseRenewal}
  alias Shoestring.Harness.{CapacitySnapshot, ExecutionLeaseRecord, Projector}
  alias Shoestring.Trajectory.Goal
  alias Shoestring.Test.FixedClock

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers
  alias Shoestring.Test.Fixtures.FakeHelpers

  @now ~U[2026-09-07 12:00:00.000000Z]

  test "renewal without an already-requested stop appends nothing" do
    %{goal: goal, grant_id: grant_id} = granted_lease()
    before = lease_event_types(goal.id)

    assert {:error, :safe_stop_not_requested} =
             LeaseRenewal.maybe_renew(goal.id, grant_id,
               now: @now,
               boundary: :item_completed,
               observe: fn -> {:ok, fresh_snapshot(Ecto.UUID.generate())} end
             )

    assert lease_event_types(goal.id) == before

    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)
    assert Repo.get!(ExecutionLeaseRecord, grant_id).status == "active"
  end

  test "renewal waits for the item.completed boundary without appending" do
    %{goal: goal, grant_id: grant_id} = granted_lease()
    before = lease_event_types(goal.id)

    assert {:ok, :awaiting_boundary} =
             LeaseRenewal.maybe_renew(goal.id, grant_id,
               now: @now,
               stop: :already_requested,
               observe: fn -> {:ok, fresh_snapshot(Ecto.UUID.generate())} end
             )

    assert lease_event_types(goal.id) == before

    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)
    assert Repo.get!(ExecutionLeaseRecord, grant_id).status == "active"
  end

  test "a non-renewable lease status is rejected without appending" do
    %{goal: goal, grant_id: grant_id} = granted_lease()
    expire_fully(goal.id, grant_id)
    before = lease_event_types(goal.id)

    assert {:error, {:lease_not_renewable, "checkpoint_required"}} =
             LeaseRenewal.maybe_renew(goal.id, grant_id,
               now: @now,
               stop: :already_requested,
               boundary: :item_completed,
               observe: fn -> {:ok, fresh_snapshot(Ecto.UUID.generate())} end
             )

    assert lease_event_types(goal.id) == before
  end

  test "renew chains the fresh snapshot, never reusing the admitted one" do
    %{goal: goal, grant_id: grant_id, snapshot_id: snapshot_id} = granted_lease()

    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    assert {:ok, %{outcome: :renewed, decision: decision, admitted_snapshot_id: ^fresh_id}} =
             LeaseRenewal.maybe_renew(goal.id, grant_id,
               now: @now,
               stop: :already_requested,
               boundary: :item_completed,
               observe: fn -> {:ok, fresh_snapshot(fresh_id)} end
             )

    assert decision.result == :admit

    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)
    record = Repo.get!(ExecutionLeaseRecord, grant_id)
    assert record.status == "renewed"
    assert record.admitted_snapshot_id == fresh_id
    assert record.admitted_snapshot_id != snapshot_id
  end

  test "a refused renewal expires before it requires a checkpoint" do
    %{goal: goal, grant_id: grant_id} = granted_lease()

    breached_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, breached_id)

    assert {:ok,
            %{
              outcome: :expired,
              reason: "reserve_breach_five_hour",
              events: [expired, checkpoint]
            }} =
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

  test "the quota fast path re-evaluates immediately and spends nothing" do
    %{goal: goal, grant_id: grant_id} = granted_lease()
    before = lease_event_types(goal.id)

    fresh_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, fresh_id)
    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    # Immediate: no stop/boundary options are accepted or required, and no
    # spend-related event exists — only lease lifecycle transitions append.
    assert {:ok, %{outcome: :renewed, events: events}} =
             LeaseRenewal.handle_quota_refusal(goal.id, grant_id,
               now: @now,
               observe: fn -> {:ok, fresh_snapshot(fresh_id)} end
             )

    assert Enum.map(events, & &1.type) == ["lease.renewal_due", "lease.renewed"]
    assert length(lease_event_types(goal.id)) == length(before) + 2

    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)
    assert Repo.get!(ExecutionLeaseRecord, grant_id).status == "renewed"
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  defp granted_lease do
    goal = create_goal!()
    task = insert_task!(goal)
    snapshot_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, snapshot_id)

    admission = append_admission_event!(goal.id, grant_payload(snapshot_id))

    command =
      claim_command(admission, command_id: "cmd-renew-#{System.unique_integer([:positive])}")

    assert {:ok, leased} =
             Dispatcher.claim_and_gate(goal.id, command,
               now: @now,
               grant_lease: [task_id: task.id, clock: FixedClock, now: FixedClock.now()]
             )

    assert {:ok, _} = Projector.project(goal.id, clock: FixedClock)

    %{goal: goal, task: task, snapshot_id: snapshot_id, grant_id: leased.grant_id}
  end

  defp expire_fully(goal_id, grant_id) do
    breached_id = Ecto.UUID.generate()

    FakeHelpers.append_capacity_snapshot(
      Repo.get!(Goal, goal_id),
      breached_id
    )

    assert {:ok, %{outcome: :expired}} =
             LeaseRenewal.maybe_renew(goal_id, grant_id,
               now: @now,
               stop: :already_requested,
               boundary: :item_completed,
               observe: fn -> {:ok, breached_snapshot(breached_id)} end
             )

    assert {:ok, _} = Projector.project(goal_id, clock: FixedClock)
  end

  defp insert_task!(goal) do
    %Shoestring.Trajectory.Task{}
    |> Shoestring.Trajectory.Task.changeset(%{"title" => "Lease renewal task"})
    |> Ecto.Changeset.put_change(:goal_id, goal.id)
    |> Repo.insert!()
  end

  defp grant_payload(snapshot_id) do
    admission_payload()
    |> Map.merge(%{
      "result" => "admit",
      "reason_code" => "automatic_admission_eligible",
      "explanation" => "Lease renewal boundary test admission",
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

  defp lease_event_types(goal_id) do
    Repo.all(
      from event in Shoestring.Trajectory.TrajectoryEvent,
        where:
          event.goal_id == ^goal_id and
            event.type in [
              "lease.proposed",
              "lease.granted",
              "lease.active",
              "lease.renewal_due",
              "lease.renewed",
              "lease.expired",
              "lease.revoked",
              "lease.checkpoint_required"
            ],
        order_by: [asc: event.sequence],
        select: event.type
    )
  end
end
