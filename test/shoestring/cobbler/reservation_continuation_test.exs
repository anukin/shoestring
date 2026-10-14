defmodule Shoestring.Cobbler.ReservationContinuationTest do
  use Shoestring.DataCase, async: false
  import Shoestring.Test.PlanExecutorHelpers
  import Shoestring.Test.PlanHandoffHelpers

  alias Shoestring.Cobbler.{
    Handoffs,
    ReservationRecord,
    ReservationSettlementRecord,
    Reservations,
    Wakeups,
    WakeupRecord
  }

  alias Shoestring.Harness.{DispatchRecord, ExecutionLeaseRecord, RunRecord}
  alias Shoestring.Test.PlanHandoffClock

  defp reserved(stop \\ :quota), do: fixture(stop, reservation_policy: %{})

  defp transfer_opts(extra \\ []) do
    perform_opts(
      Keyword.merge(
        [clock: PlanHandoffClock, reconciliation_opts: [group_probe: fn _ -> :absent end]],
        extra
      )
    )
  end

  defp root(c), do: Repo.get_by!(ReservationRecord, run_id: c.run.id)

  defp assert_chain(c, child) do
    parent = root(c)
    owner = Repo.get_by!(ReservationRecord, run_id: child.id)
    assert owner.parent_id == parent.id
    assert owner.execution_id == parent.execution_id
    assert owner.plan_task_id == parent.plan_task_id
    assert owner.attempt == parent.attempt
    assert owner.concurrency_policy == parent.concurrency_policy
    assert owner.admission_event_id != parent.admission_event_id
    assert owner.snapshot_id != parent.snapshot_id
    assert child.extensions[Reservations.key()] == owner.id
    assert Repo.get!(ReservationSettlementRecord, parent.id).kind == "consumed_closed"
    assert Reservations.outstanding() == [owner]

    assert Repo.get_by!(ExecutionLeaseRecord, run_id: child.id).admitted_snapshot_id ==
             owner.snapshot_id

    assert {:ok, %{total_attempts: 1, active_run_id: id}} =
             Shoestring.Cobbler.plan_execution_status(c.goal.id)

    assert id == child.id
    owner
  end

  test "handoff atomically closes the predecessor and acquires fresh cross-provider ownership" do
    c = reserved()
    command = request!(c)

    assert {:ok, %{outcome: :dispatched, run: child}} =
             Handoffs.perform(c.goal.id, command.command_id, transfer_opts())

    owner = assert_chain(c, child)
    assert owner.provider_id == "claude"
    assert root(c).provider_id == "codex"
    assert child.extensions["shoestring.agent:binding"]["role"] == "Reviewer"
    assert child.workspace_ref == c.run.workspace_ref

    assert {:ok, %{outcome: :converged, run: replay}} =
             Handoffs.perform(
               c.goal.id,
               command.command_id,
               transfer_opts(
                 observe: fn _ -> flunk("replayed provider observation") end,
                 reconciliation_opts: [group_probe: fn _ -> flunk("replayed ownership probe") end]
               )
             )

    assert replay.id == child.id
    assert Repo.aggregate(ReservationRecord, :count) == 2
    assert Repo.aggregate(ReservationSettlementRecord, :count) == 1
  end

  for verdict <- [:alive, :unknown] do
    test "handoff retains uncertain predecessor when group verdict is #{verdict}" do
      c = reserved()
      command = request!(c)

      assert {:error, {:reservation_parent_unsettled, reason}} =
               Handoffs.perform(
                 c.goal.id,
                 command.command_id,
                 transfer_opts(reconciliation_opts: [group_probe: fn _ -> unquote(verdict) end])
               )

      assert reason ==
               unquote(
                 if verdict == :alive, do: :process_group_alive, else: :process_group_unknown
               )

      assert Repo.get!(ReservationRecord, root(c).id).status == "reconciliation_required"
      assert Repo.aggregate(ReservationSettlementRecord, :count) == 0
      assert Repo.aggregate(ReservationRecord, :count) == 1
      assert run_count(c.goal.id) == 1

      assert {:ok, %{outcome: :dispatched, run: child}} =
               Handoffs.perform(c.goal.id, command.command_id, transfer_opts())

      assert_chain(c, child)
    end
  end

  for phase <- ["handoff.created", "dispatch.requested"] do
    test "handoff failure at #{phase} rolls back predecessor settlement and successor ownership" do
      c = reserved()
      command = request!(c)
      parent = root(c)
      # The original dispatch predates this trigger; only the successor fails.
      Ecto.Adapters.SQL.query!(
        Repo,
        "CREATE TEMP TRIGGER reject_continuation BEFORE INSERT ON trajectory_events WHEN NEW.type = '#{unquote(phase)}' BEGIN SELECT RAISE(ABORT, 'fixture continuation abort'); END"
      )

      assert_raise Exqlite.Error, fn ->
        Handoffs.perform(c.goal.id, command.command_id, transfer_opts())
      end

      assert Repo.get!(ReservationRecord, parent.id) == parent
      assert Repo.aggregate(ReservationSettlementRecord, :count) == 0
      assert Repo.aggregate(ReservationRecord, :count) == 1
      assert run_count(c.goal.id) == 1
      assert Repo.get_by(DispatchRecord, run_id: command.id) == nil
    end
  end

  defp wake_fixture do
    c = reserved(:suspended)
    terminal(c.goal, c.run, "run.interrupted")

    assert {:ok, %{wakeup: wake}} =
             Wakeups.schedule(c.goal.id,
               command_id: "reserved-wake",
               run_id: c.run.id,
               now: now(),
               clock: PlanHandoffClock
             )

    {:ok, observed} = transfer_opts()[:observe].(%{})

    observed = %{
      observed
      | source: %{observed.source | provider_id: "codex", adapter_id: "codex_app_server_stdio"},
        scope: "account:codex"
    }

    opts = [
      now: now(),
      clock: PlanHandoffClock,
      observe: fn _ -> {:ok, observed} end,
      reconciliation_opts: [group_probe: fn _ -> :absent end]
    ]

    {c, wake, opts}
  end

  test "wake holds its own reservation and lease while preserving the parent terminal and attempt" do
    {c, wake, opts} = wake_fixture()
    assert {:ok, %{branch: :admitted, dispatch: dispatch}} = Wakeups.perform_wakeup(wake.id, opts)
    child = Repo.get!(RunRecord, dispatch.run_id)
    assert child.id == wake.id
    assert child.provider_id == c.run.provider_id
    owner = assert_chain(c, child)
    assert owner.provider_id == "codex"
    assert Repo.get!(RunRecord, c.run.id).status == "interrupted"
    assert Repo.get!(WakeupRecord, wake.id).status == "woken"

    assert {:ok, _} =
             Wakeups.perform_wakeup(
               wake.id,
               Keyword.put(opts, :observe, fn _ -> flunk("replayed wake observation") end)
             )

    assert Repo.aggregate(ReservationRecord, :count) == 2
  end

  for phase <- [:dispatch, :woken] do
    test "wake #{phase} failure rolls back closure, fresh owner and wake status" do
      {c, wake, opts} = wake_fixture()
      parent = root(c)

      sql =
        case unquote(phase) do
          :dispatch ->
            "CREATE TEMP TRIGGER reject_continuation BEFORE INSERT ON trajectory_events WHEN NEW.type = 'dispatch.requested' BEGIN SELECT RAISE(ABORT, 'fixture continuation abort'); END"

          :woken ->
            "CREATE TEMP TRIGGER reject_continuation BEFORE UPDATE ON cobbler_wakeups WHEN NEW.status = 'woken' BEGIN SELECT RAISE(ABORT, 'fixture continuation abort'); END"
        end

      Ecto.Adapters.SQL.query!(Repo, sql)
      assert_raise Exqlite.Error, fn -> Wakeups.perform_wakeup(wake.id, opts) end
      assert Repo.get!(ReservationRecord, parent.id) == parent
      assert Repo.aggregate(ReservationSettlementRecord, :count) == 0
      assert Repo.aggregate(ReservationRecord, :count) == 1
      assert run_count(c.goal.id) == 1
      assert Repo.get!(WakeupRecord, wake.id).status == wake.status
      assert Repo.get!(RunRecord, c.run.id).status == "interrupted"
    end
  end

  test "a suspended checkpoint without a terminal never frees ownership" do
    c = reserved(:suspended)

    assert {:ok, %{wakeup: wake}} =
             Wakeups.schedule(c.goal.id,
               command_id: "reserved-suspended",
               run_id: c.run.id,
               now: now(),
               clock: PlanHandoffClock
             )

    {:ok, observed} = transfer_opts()[:observe].(%{})

    observed = %{
      observed
      | source: %{observed.source | provider_id: "codex", adapter_id: "codex_app_server_stdio"},
        scope: "account:codex"
    }

    assert {:error, {:reservation_parent_unsettled, :run_not_terminal}} =
             Wakeups.perform_wakeup(wake.id,
               now: now(),
               clock: PlanHandoffClock,
               observe: fn _ -> {:ok, observed} end
             )

    assert Repo.aggregate(ReservationSettlementRecord, :count) == 0
    assert Repo.aggregate(ReservationRecord, :count) == 1
    assert run_count(c.goal.id) == 1
  end
end
