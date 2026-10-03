defmodule Shoestring.Cobbler.PlannerConcurrencyTest do
  @moduledoc """
  Concurrent duplicate planner requests converge without duplicating invocations.

  Runs against a scratch SQLite database with the production migrations and
  real concurrent connections (no sandbox), proving the claim is decided by
  the unique `(goal_id, request_id)` index rather than a read-then-write
  window: at most one request records, the planner fixture is invoked exactly
  once, and the loser either sees the winner mid-flight or replays its
  stored outcome. Fully hermetic — no provider CLIs, no network.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Cobbler
  alias Shoestring.Cobbler.PlannerRequestRecord
  alias Shoestring.Test.{MigrationRepo, PlannerCallLog, PlannerHelpers}

  import Ecto.Query

  @migrations [
    {20_260_830_012_112, Shoestring.Repo.Migrations.CreateTrajectoryFoundation},
    {20_261_001_014_010, Shoestring.Repo.Migrations.AddCobblerPlanRevisions},
    {20_261_002_183_326, Shoestring.Repo.Migrations.CreateCobblerPlannerRequests}
  ]

  @other_goal_id "00000000-0000-4000-8000-0000000001d0"
  @occupant_goal_id "00000000-0000-4000-8000-0000000001e0"
  @goal_id "00000000-0000-4000-8000-0000000001c0"
  @iso_now "2026-09-07T14:00:00.000000Z"

  setup do
    state_dir =
      Path.join(
        System.tmp_dir!(),
        "shoestring-planner-race-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(state_dir)
    on_exit(fn -> File.rm_rf!(state_dir) end)

    start_supervised!({MigrationRepo,
     [
       database: Path.join(state_dir, "planner.db"),
       pool_size: 8,
       journal_mode: :wal,
       # Bounds how long a writer waits for the immediate-transaction lock
       # under full-suite load. It matches the production busy_timeout
       # (2_000, config/config.exs) and stays well below the pool checkout
       # deadline: a stalled waiter must fail with a structured busy error
       # while the lock holder still holds its lock, instead of the pool
       # timing out and disconnecting the holder mid-transaction (which
       # surfaces as a bare transaction abort).
       busy_timeout: 2_000
     ]})

    assert is_list(Ecto.Migrator.run(MigrationRepo, @migrations, :up, all: true))

    seed_goal!(MigrationRepo, @goal_id)
    log = start_supervised!({PlannerCallLog, []})

    {:ok, %{repo: MigrationRepo, log: log}}
  end

  test "concurrent identical requests invoke the planner exactly once", %{repo: repo, log: log} do
    attrs = PlannerHelpers.request_attrs()
    opts = PlannerHelpers.call_opts(log, PlannerHelpers.admitted_snapshot(), repo: repo)

    results =
      1..2
      |> Task.async_stream(
        fn _index -> Cobbler.request_plan(@goal_id, attrs, opts) end,
        max_concurrency: 2,
        timeout: :infinity
      )
      |> Enum.map(&unwrap/1)

    # The loser either sees the winner mid-flight (`in_progress`) or
    # converges on its stored outcome (`replayed`); storage contention
    # rolls back whole. What never happens, under either interleaving, is
    # two invocations, two rows, two revisions, or a raise.
    assert Enum.all?(results, &allowed_identical_outcome?/1),
           "unexpected concurrent planner outcomes: #{summarize(results)}"

    assert PlannerCallLog.count(log) == 1
    assert repo.aggregate(PlannerRequestRecord, :count, :id) == 1

    if busy?(results) do
      # A refused write lock rolled back whole: at most one revision may
      # exist, and a recorded outcome still carries exactly one revision.
      assert length(Cobbler.list_plan_revisions(@goal_id, repo: repo)) <= 1
    else
      assert Enum.count(results, &match?({:ok, %{outcome: :recorded}}, &1)) == 1
      assert length(Cobbler.list_plan_revisions(@goal_id, repo: repo)) == 1
    end
  end

  defp allowed_identical_outcome?({:ok, %{outcome: outcome}})
       when outcome in [:recorded, :replayed],
       do: true

  defp allowed_identical_outcome?({:error, {:planner_request_in_progress, _detail}}), do: true
  defp allowed_identical_outcome?(result), do: storage_failure?(result)

  defp busy?(results), do: Enum.any?(results, &storage_failure?/1)

  defp allowed_occupied_outcome?({:error, {:planner_quota_blocked, _detail}}), do: true
  defp allowed_occupied_outcome?(result), do: storage_failure?(result)

  defp allowed_distinct_outcome?({:ok, %{outcome: :recorded}}), do: true
  defp allowed_distinct_outcome?({:error, {:planner_quota_blocked, _detail}}), do: true
  defp allowed_distinct_outcome?(result), do: storage_failure?(result)

  # `Task.async_stream` reports a raised exception as `{:exit, reason}`. It
  # must fail this test by NAME, not by blowing up an unrelated pattern
  # match, because "the API raised" is precisely one of the things these
  # tests exist to catch.
  defp unwrap({:ok, result}), do: result
  defp unwrap({:exit, reason}), do: {:raised, reason}

  # The two storage-forced outcomes. Both rolled the whole transaction
  # back, so neither can have duplicated an invocation.
  defp storage_failure?({:error, {:database_busy, _message}}), do: true
  defp storage_failure?({:error, {:database_conflict, _detail}}), do: true
  defp storage_failure?(_result), do: false

  # A failing assertion must name WHICH outcome was unexpected. Collapse
  # each result to a compact tag; no fixture content is printed.
  defp summarize(results) do
    results
    |> Enum.map(fn
      {:ok, %{outcome: outcome}} -> "ok:#{outcome}"
      {:ok, other} -> "ok:#{inspect(Map.keys(other))}"
      {:error, reason} when is_tuple(reason) -> "error:#{inspect(elem(reason, 0))}"
      {:error, reason} -> "error:#{inspect(reason)}"
      {:raised, reason} -> "RAISED:#{inspect(reason, limit: 2, printable_limit: 120)}"
      other -> "other:#{inspect(other, limit: 3, printable_limit: 120)}"
    end)
    |> Enum.sort()
    |> Enum.join(", ")
  end

  test "concurrent distinct requests against an occupant invoke zero times", %{
    repo: repo,
    log: log
  } do
    seed_goal!(repo, @occupant_goal_id)

    occupant_attrs = %{
      request_id: "plan-request-occupant",
      requested_by: "human:planner",
      planner_identity: "fixture-planner",
      planner_version: "1",
      planner_model: "fixture-1",
      input_digest: String.duplicate("b", 64),
      goal_statement: "An unrelated in-flight goal.",
      base_revision: "0a1b2c3d4e5f60718293a4b5c6d7e8f901234567",
      proposal_id: "plan-request-occupant"
    }

    {:ok, _row} =
      Shoestring.Cobbler.PlannerRequestRecord.claim_changeset(
        @occupant_goal_id,
        occupant_attrs,
        ~U[2026-09-07 14:00:00.000000Z]
      )
      |> repo.insert()

    seed_goal!(repo, @other_goal_id)
    opts = PlannerHelpers.call_opts(log, PlannerHelpers.admitted_snapshot(), repo: repo)

    calls = [
      {@goal_id, PlannerHelpers.request_attrs(request_id: "plan-request-a")},
      {@other_goal_id, PlannerHelpers.request_attrs(request_id: "plan-request-b")}
    ]

    results =
      calls
      |> Task.async_stream(
        fn {goal_id, attrs} -> Cobbler.request_plan(goal_id, attrs, opts) end,
        max_concurrency: 2,
        timeout: :infinity
      )
      |> Enum.map(&unwrap/1)

    # The occupant was committed before either task started, so every
    # evaluation sees it: both requests settle blocked with zero
    # invocations (storage contention aside, which rolls back whole).
    # Either or both may still lose a write race, but nothing may invoke.
    assert Enum.all?(results, &allowed_occupied_outcome?/1),
           "unexpected concurrent planner outcomes: #{summarize(results)}"

    assert Shoestring.Test.PlannerCallLog.count(log) == 0

    assert Cobbler.list_plan_revisions(@goal_id, repo: repo) == []
    assert Cobbler.list_plan_revisions(@other_goal_id, repo: repo) == []

    unless busy?(results) do
      assert Enum.count(results, &match?({:error, {:planner_quota_blocked, _}}, &1)) == 2

      for {:error, {:planner_quota_blocked, detail}} <- results do
        assert detail["reason_code"] == "scope_occupied"
        assert detail["attempts_used"] == 0
      end
    end
  end

  test "an uncoordinated distinct race keeps accounting balanced", %{repo: repo, log: log} do
    seed_goal!(repo, @other_goal_id)
    opts = PlannerHelpers.call_opts(log, PlannerHelpers.admitted_snapshot(), repo: repo)

    calls = [
      {@goal_id, PlannerHelpers.request_attrs(request_id: "plan-request-a")},
      {@other_goal_id, PlannerHelpers.request_attrs(request_id: "plan-request-b")}
    ]

    results =
      calls
      |> Task.async_stream(
        fn {goal_id, attrs} -> Cobbler.request_plan(goal_id, attrs, opts) end,
        max_concurrency: 2,
        timeout: :infinity
      )
      |> Enum.map(&unwrap/1)

    # Without a pre-seated occupant the tasks may serialize (both record)
    # or overlap (at most one records): every interleaving must still
    # balance — every recorded proposal paid exactly one invocation, every
    # blocked request spent zero attempts, and nothing raised.
    assert Enum.all?(results, &allowed_distinct_outcome?/1),
           "unexpected concurrent planner outcomes: #{summarize(results)}"

    unless busy?(results) do
      recorded = Enum.count(results, &match?({:ok, %{outcome: :recorded}}, &1))

      revisions =
        length(Cobbler.list_plan_revisions(@goal_id, repo: repo)) +
          length(Cobbler.list_plan_revisions(@other_goal_id, repo: repo))

      assert Shoestring.Test.PlannerCallLog.count(log) == recorded
      assert revisions == recorded
    end
  end

  test "a held invocation blocks a distinct request with zero second invocation", %{
    repo: repo,
    log: log
  } do
    test_pid = self()

    opts =
      PlannerHelpers.call_opts(log, PlannerHelpers.admitted_snapshot(),
        repo: repo,
        adapter: Shoestring.Test.BarrierPlanner,
        fixture: %{barrier: test_pid}
      )

    held_attrs = PlannerHelpers.request_attrs(request_id: "plan-request-held")
    held = Task.async(fn -> Cobbler.request_plan(@goal_id, held_attrs, opts) end)
    held_ref = Process.monitor(held.pid)

    # The first invocation is inside the adapter now: admitted, attempt
    # consumed, invocation open.
    assert_receive {:entered, holder_pid}, 10_000

    # While it is held, a distinct request through the public API must
    # settle blocked without a second invocation. The denied task must
    # complete on its own: any adapter entry would precede its completion,
    # so an empty mailbox afterwards proves the denial caused zero
    # invocations (causal ordering, not timing).
    denied_attrs = PlannerHelpers.request_attrs(request_id: "plan-request-denied")

    denied =
      Task.async(fn -> Cobbler.request_plan(@goal_id, denied_attrs, opts) end)

    denied_ref = Process.monitor(denied.pid)

    denied_result =
      case Task.yield(denied, 15_000) || Task.shutdown(denied) do
        {:ok, result} -> result
        nil -> flunk("denied request did not settle while the first invocation was held")
      end

    assert {:error, {:planner_quota_blocked, detail}} = denied_result
    assert detail["reason_code"] == "scope_occupied"
    assert detail["attempts_used"] == 0
    assert_receive {:DOWN, ^denied_ref, :process, _, :normal}
    refute_received {:entered, _}

    denied_row = Cobbler.planner_request(@goal_id, "plan-request-denied", repo: repo)
    assert denied_row.status == "manual_required"
    assert denied_row.error_kind == "quota_blocked"
    assert denied_row.attempts_used == 0

    # Release explicitly: the held request settles proposed with exactly
    # one invocation and one revision across the whole run.
    send(holder_pid, :release)
    assert {:ok, %{request: held_request, outcome: :recorded}} = Task.await(held, 15_000)
    assert held_request.status == "proposed"
    assert_receive {:DOWN, ^held_ref, :process, _, :normal}

    assert Shoestring.Test.PlannerCallLog.count(log) == 1
    assert length(Cobbler.list_plan_revisions(@goal_id, repo: repo)) == 1
    assert event_count(repo, @goal_id, ["cobbler.planner.resolved"]) == 2

    # The settled scope admits again: a subsequent request invokes and
    # proposes a second revision.
    next_attrs =
      PlannerHelpers.request_attrs(request_id: "plan-request-next", parent_revision_number: 1)

    nxt = Task.async(fn -> Cobbler.request_plan(@goal_id, next_attrs, opts) end)
    nxt_ref = Process.monitor(nxt.pid)
    assert_receive {:entered, next_holder}, 10_000
    send(next_holder, :release)
    assert {:ok, %{request: next_request, outcome: :recorded}} = Task.await(nxt, 15_000)
    assert next_request.status == "proposed"
    assert next_request.revision_number == 2
    assert_receive {:DOWN, ^nxt_ref, :process, _, :normal}

    assert Shoestring.Test.PlannerCallLog.count(log) == 2
    assert length(Cobbler.list_plan_revisions(@goal_id, repo: repo)) == 2
  end

  defp event_count(repo, goal_id, types) do
    import Ecto.Query

    repo.aggregate(
      from(event in Shoestring.Trajectory.TrajectoryEvent,
        where: event.goal_id == ^goal_id and event.type in ^types
      ),
      :count,
      :id
    )
  end

  defp seed_goal!(repo, id) do
    repo.query!(
      "INSERT INTO goals (id, owner_id, title, status, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
      [
        id,
        "00000000-0000-4000-8000-0000000000ff",
        "Planner race goal",
        "active",
        @iso_now,
        @iso_now
      ]
    )

    %{id: id}
  end
end
