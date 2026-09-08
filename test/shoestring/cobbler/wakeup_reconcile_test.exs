defmodule Shoestring.Cobbler.WakeupReconcileTest do
  @moduledoc """
  Hermetic DataCase tests for wakeup startup reconcile: boot repair of rows
  without a live delivery attempt, no-dupe re-runs, and terminal-goal
  cancellation.

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
  alias Shoestring.Test.ManualClock

  @t0 ~U[2026-09-07 12:00:00.000000Z]

  setup do
    ManualClock.set(@t0)
    {:ok, goal: create_goal!()}
  end

  test "boot repair: a row without a live job gets one re-enqueued", %{goal: goal} do
    wakeup = insert_row!(goal, wake_at: @t0, status: "due")
    assert job_count(wakeup.id) == 0

    assert {:ok, %{repaired_count: 1, failures: []}} = Wakeups.reconcile(now: @t0)

    assert job_count(wakeup.id) == 1
    assert Repo.get!(WakeupRecord, wakeup.id).status == "due"
  end

  test "no dupes: a second pass repairs nothing and enqueues nothing", %{goal: goal} do
    wakeup = insert_row!(goal, wake_at: @t0, status: "due")

    assert {:ok, %{repaired_count: 1}} = Wakeups.reconcile(now: @t0)
    assert {:ok, %{repaired_count: 0, failures: []}} = Wakeups.reconcile(now: @t0)
    assert job_count(wakeup.id) == 1
  end

  test "past-due scheduled rows flip to due", %{goal: goal} do
    wakeup = insert_row!(goal, wake_at: DateTime.add(@t0, -60, :second), status: "scheduled")

    assert {:ok, %{failures: []}} = Wakeups.reconcile(now: @t0)
    assert Repo.get!(WakeupRecord, wakeup.id).status == "due"
  end

  test "future scheduled rows are left scheduled (with a live job)", %{goal: goal} do
    wakeup =
      insert_row!(goal, wake_at: DateTime.add(@t0, 3_600, :second), status: "scheduled")

    assert {:ok, %{failures: []}} = Wakeups.reconcile(now: @t0)
    assert Repo.get!(WakeupRecord, wakeup.id).status == "scheduled"
    assert job_count(wakeup.id) == 1
  end

  test "terminal-goal rows are cancelled", %{goal: goal} do
    wakeup = insert_row!(goal, wake_at: @t0, status: "due")
    complete_goal!(goal)

    assert {:ok, %{repaired_count: 1, failures: []}} = Wakeups.reconcile(now: @t0)
    assert Repo.get!(WakeupRecord, wakeup.id).status == "cancelled"
    assert job_count(wakeup.id) == 0
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  defp insert_row!(goal, opts) do
    %WakeupRecord{}
    |> WakeupRecord.changeset(%{
      goal_id: goal.id,
      wake_at: Keyword.fetch!(opts, :wake_at),
      reason: "scheduled",
      status: Keyword.fetch!(opts, :status),
      idempotency_key: "wakeup:#{goal.id}:cmd-reconcile-#{Ecto.UUID.generate()}",
      inserted_at: @t0,
      updated_at: @t0
    })
    |> Repo.insert!()
  end

  defp complete_goal!(goal) do
    goal
    |> Ecto.Changeset.change(%{status: "completed"})
    |> Repo.update!()
  end

  defp job_count(wakeup_id) do
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
end
