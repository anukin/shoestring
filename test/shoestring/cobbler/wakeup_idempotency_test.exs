defmodule Shoestring.Cobbler.WakeupIdempotencyTest do
  @moduledoc """
  Hermetic DataCase tests for wake intent idempotency: scheduling the same
  durable identity twice yields one effect, and re-performing a `woken` row
  is a no-op.

  Locking note (standing contract): wakeups are new surface in this slice,
  so on the pre-fix commit these tests error on the missing table/modules
  (documentation, not behavior-change locks). Stated honestly here rather
  than claimed as coverage.
  """
  use Shoestring.DataCase, async: false

  import Ecto.Query
  import Shoestring.Test.CobblerHelpers

  alias Oban.Job
  alias Shoestring.Cobbler.{Wakeups, WakeupRecord}
  alias Shoestring.Harness.CapacitySnapshot
  alias Shoestring.Test.ManualClock
  alias Shoestring.Trajectory.TrajectoryEvent

  @t0 ~U[2026-09-07 12:00:00.000000Z]

  setup do
    ManualClock.set(@t0)
    {:ok, goal: create_goal!()}
  end

  test "the same command key twice yields one row and one effect", %{goal: goal} do
    opts = [command_id: "cmd-dupe", wake_at: @t0, now: @t0, clock: ManualClock]

    assert {:ok, %{outcome: :recorded, wakeup: first}} = Wakeups.schedule(goal.id, opts)

    assert {:ok, %{outcome: :replayed, wakeup: second, job: nil}} =
             Wakeups.schedule(goal.id, opts)

    assert second.id == first.id
    assert wakeup_count(goal.id) == 1
    assert wakeup_job_count(first.id) == 1
  end

  test "the same decision key twice yields one effect", %{goal: goal} do
    defer_until = DateTime.add(@t0, 300, :second)

    opts = [
      decision_id: Ecto.UUID.generate(),
      defer_until: defer_until,
      now: @t0,
      clock: ManualClock
    ]

    assert {:ok, %{outcome: :recorded}} = Wakeups.schedule(goal.id, opts)
    assert {:ok, %{outcome: :replayed}} = Wakeups.schedule(goal.id, opts)
    assert wakeup_count(goal.id) == 1
  end

  test "a terminal row under the same key schedules anew with a durable suffix", %{
    goal: goal
  } do
    opts = [command_id: "cmd-resleep", wake_at: @t0, now: @t0, clock: ManualClock]
    assert {:ok, %{wakeup: first}} = Wakeups.schedule(goal.id, opts)

    {:ok, _} =
      first |> Ecto.Changeset.change(%{status: "woken"}) |> Repo.update()

    assert {:ok, %{outcome: :recorded, wakeup: second}} = Wakeups.schedule(goal.id, opts)

    assert second.id != first.id
    assert second.idempotency_key == "#{first.idempotency_key}:r1"
    assert wakeup_count(goal.id) == 2
  end

  test "re-performing a woken row is a no-op with no new events", %{goal: goal} do
    admission = append_admission_event!(goal.id)
    snapshot = unknown_snapshot!()

    assert {:ok, %{wakeup: wakeup}} =
             Wakeups.schedule(goal.id,
               command_id: "cmd-noop",
               wake_at: @t0,
               now: @t0,
               clock: ManualClock,
               decision_event_id: admission.id
             )

    perform_opts = [now: @t0, clock: ManualClock, observe: fn -> {:ok, snapshot} end]

    # No run is attached: the admit branch (unknown capacity without an
    # override demands confirmation instead) ...
    assert {:ok, first} = Wakeups.perform_wakeup(wakeup.id, perform_opts)
    assert first.branch == :require_confirmation
    assert Repo.get!(WakeupRecord, wakeup.id).status == "woken"

    events_after_first = Repo.aggregate(TrajectoryEvent, :count, :id)

    assert {:ok, %{outcome: :already_woken, branch: :already_woken}} =
             Wakeups.perform_wakeup(wakeup.id, perform_opts)

    assert Repo.aggregate(TrajectoryEvent, :count, :id) == events_after_first
  end

  test "scheduling without an identity fails closed", %{goal: goal} do
    assert {:error, :missing_wakeup_identity} =
             Wakeups.schedule(goal.id, now: @t0, clock: ManualClock)
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  defp wakeup_count(goal_id) do
    Repo.aggregate(from(w in WakeupRecord, where: w.goal_id == ^goal_id), :count, :id)
  end

  defp wakeup_job_count(wakeup_id) do
    Repo.aggregate(
      from(job in Job,
        where:
          job.queue == "wakeup" and
            fragment("json_extract(?, '$.wakeup_id') = ?", job.args, ^wakeup_id)
      ),
      :count,
      :id
    )
  end

  defp unknown_snapshot! do
    now = ManualClock.now()

    {:ok, snapshot} =
      CapacitySnapshot.new(
        %{
          version: 2,
          snapshot_id: Ecto.UUID.generate(),
          capacity_state: :unknown,
          windows: [
            %{kind: "five_hour", state: :unknown, reason: "no reading yet"},
            %{kind: "weekly", state: :unknown, reason: "no reading yet"}
          ],
          observed_at: now,
          freshness: %{max_age_seconds: 300},
          source: %{
            adapter_id: "shoestring.harness.fake",
            provider_id: "codex",
            invocation_mode: "headless",
            event: :explicit_read
          },
          scope: "account:codex",
          confidence: :none,
          support_tier: :proactive,
          compatibility_state: :compatible,
          reason: "no reading yet",
          extensions: %{}
        },
        now: now
      )

    snapshot
  end
end
