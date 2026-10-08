defmodule Shoestring.Cobbler.PlanApprovalRaceTest do
  @moduledoc """
  SQLite-enforced single plan authority under real concurrency.

  Runs against a scratch SQLite database with the production migrations and
  real concurrent connections (no sandbox), proving there is no
  read-then-write window: two approvals racing for the same goal serialize
  on immediate write transactions and the partial unique index rejects the
  second approved revision. Fully hermetic — no provider CLIs, no network.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Cobbler.{PlanDecisionRecord, PlanRevisionRecord, Plans}
  alias Shoestring.Test.MigrationRepo

  import Ecto.Query
  import Shoestring.Test.PlanFixtures

  @migrations [
    {20_260_830_012_112, Shoestring.Repo.Migrations.CreateTrajectoryFoundation},
    {20_261_001_014_010, Shoestring.Repo.Migrations.AddCobblerPlanRevisions}
  ]

  @goal_id "00000000-0000-4000-8000-000000000101"
  @now ~U[2026-09-30 12:00:00.000000Z]
  @iso_now DateTime.to_iso8601(@now)

  setup do
    state_dir =
      Path.join(System.tmp_dir!(), "shoestring-plan-race-#{System.unique_integer([:positive])}")

    File.mkdir_p!(state_dir)
    on_exit(fn -> File.rm_rf!(state_dir) end)

    start_supervised!({MigrationRepo,
     [
       database: Path.join(state_dir, "plans.db"),
       pool_size: 8,
       journal_mode: :wal,
       # Match production's lock-wait bound. Waiting for the full 15s query
       # timeout can occupy dirty-I/O slots and prevent the lock owner from
       # progressing before DBConnection aborts it. Keep the wait shorter;
       # the exactly-one-decision assertions and four writers are unchanged.
       busy_timeout: 2_000
     ]})

    assert is_list(Ecto.Migrator.run(MigrationRepo, @migrations, :up, all: true))

    seed_goal!(MigrationRepo, @goal_id)

    {:ok, %{repo: MigrationRepo}}
  end

  defp call_opts(repo), do: [repo: repo, publish_fun: fn _event -> :ok end, now: @now]

  test "two approvals racing for the SAME revision leave exactly one decision", %{repo: repo} do
    revision = propose!(repo, "proposal-1", plan(), nil)

    results =
      [
        approve_attrs(1, revision.digest, decision_id: "decision-a"),
        approve_attrs(1, revision.digest, decision_id: "decision-b")
      ]
      |> Task.async_stream(
        fn attrs -> Plans.approve(@goal_id, attrs, call_opts(repo)) end,
        max_concurrency: 2,
        timeout: :infinity
      )
      |> Enum.map(&unwrap/1)

    recorded = Enum.count(results, &match?({:ok, %{outcome: :recorded}}, &1))

    # At most one approval may commit. A writer refused the SQLite write
    # lock rolls back whole and is reported structurally, so "busy" is an
    # allowed outcome here; "both committed" never is.
    assert recorded <= 1
    assert repo.aggregate(PlanDecisionRecord, :count, :id) == recorded
    assert approved_count(repo) == recorded
    assert approved_event_count(repo) == recorded

    unless busy?(results) do
      assert recorded == 1
      assert Enum.count(results, &match?({:error, _reason}, &1)) == 1
    end
  end

  test "two approvals racing for sibling revisions never leave two authorities", %{repo: repo} do
    first = propose!(repo, "proposal-1", plan(), nil)

    second =
      propose!(
        repo,
        "proposal-2",
        plan(%{"goal" => goal(%{"statement" => "A sibling edit of the same plan."})}),
        1
      )

    results =
      [
        approve_attrs(1, first.digest, decision_id: "decision-a"),
        approve_attrs(2, second.digest, decision_id: "decision-b")
      ]
      |> Task.async_stream(
        fn attrs -> Plans.approve(@goal_id, attrs, call_opts(repo)) end,
        max_concurrency: 2,
        timeout: :infinity
      )
      |> Enum.map(&unwrap/1)

    assert length(results) == 2

    # Both orderings are legitimate and both are safe:
    #
    #   * revision 1 commits first, then revision 2 commits and supersedes
    #     it. Two decisions, one authority.
    #   * revision 2 commits first, then revision 1 is refused as stale
    #     because a newer revision already holds authority. One decision,
    #     one authority.
    #
    # What must never happen, under either interleaving, is two approved
    # revisions or an authority nobody decided on.
    assert approved_count(repo) <= 1

    if busy?(results) do
      # A refused write lock rolls back whole: there is still never a
      # second authority and never a decision without its revision.
      assert repo.aggregate(PlanDecisionRecord, :count, :id) == approved_count(repo)
    else
      assert approved_count(repo) == 1
      assert_single_authority(repo, results)
    end
  end

  defp assert_single_authority(repo, results) do
    authority = Plans.authority(@goal_id, repo: repo)
    assert authority.revision_number in [1, 2]

    case Enum.count(results, &match?({:ok, %{outcome: :recorded}}, &1)) do
      2 ->
        assert authority.revision_number == 2
        assert revision_status(repo, 1) == "superseded"
        assert repo.aggregate(PlanDecisionRecord, :count, :id) == 2

      1 ->
        assert [{:error, {:plan_revision_stale, detail}}] =
                 Enum.filter(results, &match?({:error, _reason}, &1))

        assert detail["approved_revision_number"] == 2
        assert detail["requested_revision_number"] == 1
        assert authority.revision_number == 2
        assert revision_status(repo, 1) == "proposed"
        assert repo.aggregate(PlanDecisionRecord, :count, :id) == 1
    end
  end

  defp busy?(results), do: Enum.any?(results, &storage_failure?/1)

  # `Task.async_stream` reports a raised exception as `{:exit, reason}`. It
  # must fail this test by NAME, not by blowing up an unrelated pattern
  # match, because "the API raised" is precisely one of the things these
  # tests exist to catch.
  defp unwrap({:ok, result}), do: result
  defp unwrap({:exit, reason}), do: {:raised, reason}

  defp allowed_identical_outcome?({:ok, %{outcome: outcome}})
       when outcome in [:recorded, :replayed],
       do: true

  defp allowed_identical_outcome?(result), do: storage_failure?(result)

  # The two storage-forced outcomes. Both rolled the whole transaction
  # back, so neither can have double-authorized. `:database_conflict` is
  # NOT a widening of what this test tolerates: before the fix the same
  # condition escaped as a raw exception, which this test now also refuses
  # by name via `unwrap/1`.
  defp storage_failure?({:error, {:database_busy, _message}}), do: true
  defp storage_failure?({:error, {:database_conflict, _detail}}), do: true
  defp storage_failure?(_result), do: false

  # A failing assertion must name WHICH outcome was unexpected. Inspecting
  # the raw results prints whole revision structs and the pretty-printer
  # truncates the interesting element away, so collapse each result to a
  # compact tag. No fixture content and no identifiers are printed.
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

  test "the same approval replayed concurrently records one decision and one event", %{
    repo: repo
  } do
    revision = propose!(repo, "proposal-1", plan(), nil)
    attrs = approve_attrs(1, revision.digest, decision_id: "decision-replay")

    results =
      1..4
      |> Task.async_stream(
        fn _index -> Plans.approve(@goal_id, attrs, call_opts(repo)) end,
        max_concurrency: 4,
        timeout: :infinity
      )
      |> Enum.map(&unwrap/1)

    # An identical re-approval always MEANS the same thing, so it either
    # succeeds (recorded, or replayed onto the winner's row) or it fails in
    # a way the storage layer forced and that rolled back whole. It never
    # raises, and it never reports a plan-level refusal: a request that
    # merely lost a race has not been refused, it has already succeeded.
    assert Enum.all?(results, &allowed_identical_outcome?/1),
           "unexpected concurrent approval outcomes: #{summarize(results)}"

    # Whatever the interleaving, the decision is recorded exactly once.
    assert Enum.count(results, &match?({:ok, %{outcome: :recorded}}, &1)) == 1

    assert repo.aggregate(PlanDecisionRecord, :count, :id) == 1
    assert approved_event_count(repo) == 1
    assert approved_count(repo) == 1
    assert Plans.authority(@goal_id, repo: repo).revision_number == 1
  end

  defp propose!(repo, proposal_id, plan, parent) do
    attrs =
      propose_attrs(proposal_id: proposal_id, plan: plan, parent_revision_number: parent)

    assert {:ok, %{revision: revision}} = Plans.propose(@goal_id, attrs, call_opts(repo))
    revision
  end

  defp approved_count(repo) do
    repo.aggregate(
      from(revision in PlanRevisionRecord, where: revision.status == "approved"),
      :count,
      :id
    )
  end

  defp revision_status(repo, revision_number) do
    Plans.get_revision(@goal_id, revision_number, repo: repo).status
  end

  defp approved_event_count(repo) do
    repo.aggregate(
      from(event in Shoestring.Trajectory.TrajectoryEvent,
        where: event.type == "cobbler.plan.approved"
      ),
      :count,
      :id
    )
  end

  defp seed_goal!(repo, id) do
    repo.query!(
      "INSERT INTO goals (id, owner_id, title, status, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
      [id, "00000000-0000-4000-8000-0000000000ff", "Plan race goal", "active", @iso_now, @iso_now]
    )

    %{id: id}
  end
end
