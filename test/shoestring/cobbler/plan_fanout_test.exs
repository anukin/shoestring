defmodule Shoestring.Cobbler.PlanFanoutTest do
  @moduledoc "New-capability tests for internal sibling coordination; no live provider or automatic worker activation."
  use Shoestring.DataCase, async: false
  import Shoestring.Test.PlanFanoutHelpers

  alias Shoestring.Cobbler.{
    Commands,
    PlanExecutor,
    PlanFanout,
    ReservationPolicy,
    ReservationRecord,
    Reservations
  }

  alias Shoestring.Harness.{Dispatches, DispatchRecord, RunRecord, Projector}
  alias Shoestring.Test.{CobblerHelpers, PlanExecutorHelpers}
  alias Shoestring.Trajectory.TrajectoryEvent
  alias Shoestring.Worktrees

  test "two ready roots persist isolated owned intents and reconstruct all active children" do
    c = unit_fixture()
    assert {:ok, result} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
    assert Enum.map(result.dispatched, & &1.plan_task_id) == ["north", "south"]
    assert result.blocked == []
    assert result.queue_policy_version == 1
    assert Commands.active_claim() == nil
    assert Repo.aggregate(RunRecord, :count) == 2
    assert Repo.aggregate(ReservationRecord, :count) == 2
    assert Repo.aggregate(Oban.Job, :count) == 2
    [north, south] = result.dispatched
    {:ok, left} = Worktrees.get(north.run_id, c.opts)
    {:ok, right} = Worktrees.get(south.run_id, c.opts)
    assert left.repo_path != right.repo_path
    assert left.base_commit == c.base and right.base_commit == c.base
    assert git!(left.path, ["remote"]) == "" and git!(right.path, ["remote"]) == ""
    assert git!(c.source, ["status", "--porcelain"]) == ""
    assert git!(c.source, ["rev-parse", "HEAD"]) |> String.trim() == c.base
    assert {:ok, _} = Projector.rebuild(c.goal.id)
    assert {:ok, status} = PlanExecutor.status(c.goal.id, c.opts)
    assert status.dispatch_mode == :fanout_v1
    assert Enum.map(status.active_children, & &1.plan_task_id) == ["north", "south"]
    assert Enum.sort(status.active_run_ids) == Enum.sort(Enum.map(result.dispatched, & &1.run_id))
    assert status.total_attempts == 2

    assert {:ok, %{dispatched: [], blocked: []}} =
             PlanFanout.dispatch_ready(
               c.goal.id,
               Keyword.put(c.opts, :admission_fun, fn _, _, _, _ ->
                 flunk("duplicate admission")
               end)
             )

    assert Repo.aggregate(Oban.Job, :count) == 2
  end

  test "overlapping or unknown scopes record blockers without allocating work" do
    for hints <- [
          %{"files" => ["lib/north.ex"], "symbols" => []},
          %{"files" => [], "symbols" => []}
        ] do
      c =
        unit_fixture(
          transform_tasks: fn [north, south, join] ->
            [north, Map.put(south, "hints", hints), join]
          end
        )

      assert {:ok, %{disposition: :blocked, reason: :independence_unverified, decision: decision}} =
               PlanFanout.dispatch_ready(c.goal.id, c.opts)

      assert decision["blocker_count"] > 0
      assert Worktrees.list(c.opts) == []
      assert PlanExecutorHelpers.run_count(c.goal.id) == 0
    end
  end

  test "configured provider cap holds the second task without duplicate or unowned intent" do
    c = unit_fixture()

    opts =
      Keyword.put(c.opts, :reservation_policy, %{
        global_limit: 2,
        goal_limit: 2,
        provider_account_limit: 1,
        account_units: 2
      })

    assert {:ok, result} = PlanFanout.dispatch_ready(c.goal.id, opts)
    assert [%{plan_task_id: "north"}] = result.dispatched

    assert [%{plan_task_id: "south", reason: {:reservation_blocked, :provider_account_limit}}] =
             result.blocked

    assert Repo.aggregate(RunRecord, :count) == 1
    assert Repo.aggregate(Oban.Job, :count) == 1
    assert length(Reservations.outstanding()) == 1

    assert {:error, :not_found} =
             Worktrees.get(PlanExecutor.task_run_id(c.goal.id, "south", 1), c.opts)
  end

  test "blocked first provider does not prevent an otherwise safe second task" do
    c = unit_fixture()
    other = CobblerHelpers.create_goal!()
    admission = admission!(other)

    {:ok, policy} =
      ReservationPolicy.new(%{
        global_limit: 2,
        goal_limit: 2,
        provider_account_limit: 1,
        account_units: 2
      })

    attrs = %{
      id: Ecto.UUID.generate(),
      goal_id: other.id,
      execution_id: Ecto.UUID.generate(),
      plan_task_id: "other",
      attempt: 1,
      run_id: Ecto.UUID.generate(),
      admission_event_id: admission.id
    }

    assert {:ok, owner} = Reservations.hold(attrs, policy, now: PlanExecutorHelpers.now())

    admit = fn _, _, task, _ ->
      changes =
        if task["id"] == "south",
          do: %{
            "candidate" => %{
              "provider_id" => "alternate-fixture-provider",
              "adapter_id" => Shoestring.Harness.Fake.identity().adapter_id,
              "support_tier" => "proactive",
              "compatibility_state" => "compatible"
            }
          },
          else: %{}

      {:ok, admission!(c.goal, changes).id}
    end

    opts = Keyword.merge(c.opts, reservation_policy: policy, admission_fun: admit)
    assert {:ok, result} = PlanFanout.dispatch_ready(c.goal.id, opts)
    assert [%{plan_task_id: "south"}] = result.dispatched

    assert [%{plan_task_id: "north", reason: {:reservation_blocked, :provider_account_limit}}] =
             result.blocked

    assert Enum.any?(Reservations.outstanding(), &(&1.id == owner.id))
  end

  test "duration allowance preserves space for the worst-case global gate" do
    c = unit_fixture(independent_only: true, task_seconds: 600, goal_seconds: 1200)
    assert {:ok, result} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
    assert [%{plan_task_id: "north"}] = result.dispatched

    assert [%{plan_task_id: "south", reason: :fanout_duration_allowance_exhausted}] =
             result.blocked

    assert Repo.aggregate(ReservationRecord, :count) == 1
    assert PlanExecutorHelpers.run_count(c.goal.id) == 1
  end

  test "admitted lease bounds cannot exceed the task's duration contract" do
    c = unit_fixture(independent_only: true, task_seconds: 60)
    assert {:ok, result} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
    assert result.dispatched == []
    assert length(result.blocked) == 2
    assert Enum.all?(result.blocked, &(&1.reason == :fanout_lease_exceeds_task_budget))
    assert Repo.aggregate(ReservationRecord, :count) == 0
    assert Worktrees.list(c.opts) == []
  end

  test "an unresolved owner past its task duration never becomes free future allowance" do
    c = unit_fixture(independent_only: true, task_seconds: 600, goal_seconds: 1200)
    assert {:ok, %{dispatched: [north]}} = PlanFanout.dispatch_ready(c.goal.id, c.opts)

    for type <- ~w(run.starting run.running) do
      assert {:ok, _} =
               Shoestring.Trajectory.append(
                 c.goal.id,
                 %{
                   "type" => type,
                   "schema_version" => 1,
                   "actor" => "test",
                   "occurred_at" => PlanExecutorHelpers.now(),
                   "payload" => %{"run_id" => north.run_id}
                 },
                 trusted: [run_id: north.run_id]
               )
    end

    future = DateTime.add(PlanExecutorHelpers.now(), 601)

    admit = fn _, _, _, _ ->
      admission =
        admission!(c.goal, %{
          "evaluated_at" => DateTime.to_iso8601(future),
          "proposed_bounds" => %{
            "response_budget" => 10,
            "tool_budget" => 25,
            "checkpoint_cadence" => 1,
            "reserves" => %{"response" => 1, "tool" => 1},
            "deadline" => DateTime.to_iso8601(DateTime.add(future, 300))
          }
        })

      {:ok, admission.id}
    end

    assert {:ok, %{dispatched: [], blocked: [%{reason: :fanout_duration_owner_exhausted}]}} =
             PlanFanout.dispatch_ready(
               c.goal.id,
               Keyword.merge(c.opts, now: future, admission_fun: admit)
             )

    assert Enum.map(Reservations.outstanding(), & &1.run_id) == [north.run_id]
    assert Repo.aggregate(RunRecord, :count) == 1
  end

  test "untracked source changes refuse further intent" do
    c = unit_fixture()
    File.write!(Path.join(c.source, "unexpected.txt"), "retain source change\n")

    assert {:error, :repository_base_or_state_changed} =
             PlanFanout.dispatch_ready(c.goal.id, c.opts)

    assert Worktrees.list(c.opts) == []
    assert File.read!(Path.join(c.source, "unexpected.txt")) == "retain source change\n"
  end

  test "approval changed by admission after selection creates no sibling intent" do
    c = unit_fixture()

    admit = fn _, _, task, _ ->
      if task["id"] == "north" do
        plan =
          Map.update!(c.plan, "tasks", fn [north, south, join] ->
            [Map.put(north, "outcome", "A newly approved outcome"), south, join]
          end)

        assert {:ok, %{revision: revision}} =
                 Shoestring.Cobbler.Plans.propose(
                   c.goal.id,
                   Shoestring.Test.PlanFixtures.propose_attrs(
                     plan: plan,
                     proposal_id: "changed",
                     parent_revision_number: 1
                   ),
                   now: PlanExecutorHelpers.now()
                 )

        assert {:ok, _} =
                 Shoestring.Cobbler.Plans.approve(
                   c.goal.id,
                   Shoestring.Test.PlanFixtures.approve_attrs(2, revision.digest,
                     decision_id: "changed-approval"
                   ),
                   now: PlanExecutorHelpers.now()
                 )
      end

      {:ok, admission!(c.goal).id}
    end

    assert {:ok, result} =
             PlanFanout.dispatch_ready(c.goal.id, Keyword.put(c.opts, :admission_fun, admit))

    assert result.dispatched == []
    assert Enum.all?(result.blocked, &match?({:authority_mismatch, _}, &1.reason))
    assert Repo.aggregate(RunRecord, :count) == 0
    assert Repo.aggregate(ReservationRecord, :count) == 0
    assert Worktrees.list(c.opts) == []
  end

  test "one unavailable completion workspace does not hide a successful sibling" do
    c = unit_fixture()
    assert {:ok, result} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
    [north, south] = result.dispatched
    for child <- result.dispatched, do: complete_child!(c.goal, child.run_id)

    Repo.get!(RunRecord, north.run_id)
    |> Ecto.Changeset.change(workspace_ref: "foreign-workspace")
    |> Repo.update!()

    assert {:error, :plan_worktree_mismatch} = PlanExecutor.resume(c.goal.id, c.opts)
    assert {:ok, status} = PlanExecutor.status(c.goal.id, c.opts)
    assert status.accepted == ["south"]
    assert Enum.map(status.active_children, & &1.run_id) == [north.run_id]
    assert Enum.find(status.children, &(&1.run_id == south.run_id)).resolved?
  end

  test "runtime opt-in and explicit policy are required" do
    c = unit_fixture()

    assert {:error, :fanout_configuration_required} =
             PlanFanout.dispatch_ready(c.goal.id, Keyword.delete(c.opts, :fanout_enabled))

    assert {:error, :fanout_reservation_policy_required} =
             PlanFanout.dispatch_ready(c.goal.id, Keyword.delete(c.opts, :reservation_policy))

    assert Repo.aggregate(RunRecord, :count) == 0
    assert Worktrees.list(c.opts) == []
  end

  test "generic executor options cannot switch to reservation-owned sibling dispatch" do
    c = unit_fixture()

    assert {:ok, result} =
             PlanExecutor.advance(c.goal.id, Keyword.put(c.opts, :reserved_sibling, true))

    run = Repo.get!(RunRecord, result.run_id)
    refute Map.has_key?(run.extensions, "shoestring.fanout:version")
    assert Commands.active_claim().goal_id == c.goal.id
    assert {:ok, %{dispatch_mode: :sequential}} = PlanExecutor.status(c.goal.id, c.opts)

    assert {:error, :fanout_execution_authority_required} =
             PlanFanout.dispatch_ready(c.goal.id, c.opts)
  end

  test "observed out-of-scope or conflicting sibling work blocks new admission and is retained" do
    c = unit_fixture()
    assert {:ok, result} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
    [north, _] = result.dispatched
    {:ok, tree} = Worktrees.get(north.run_id, c.opts)

    File.write!(
      Path.join(tree.path, "lib/south.ex"),
      "defmodule South do\n  def unexpected, do: true\nend\n"
    )

    assert {:ok, %{disposition: :blocked, decision: decision}} =
             PlanFanout.dispatch_ready(
               c.goal.id,
               Keyword.put(c.opts, :admission_fun, fn _, _, _, _ ->
                 flunk("admission after scope refusal")
               end)
             )

    assert Enum.any?(decision["blockers"], &(&1["reason"] == "outside_declared_scope"))
    assert File.read!(Path.join(tree.path, "lib/south.ex")) =~ "unexpected"
    assert Repo.aggregate(RunRecord, :count) == 2
  end

  test "foreign child ownership cannot be treated as accounted-for parallel work" do
    c = unit_fixture()
    assert {:ok, result} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
    [north, _] = result.dispatched
    run = Repo.get!(RunRecord, north.run_id)

    run
    |> Ecto.Changeset.change(
      extensions: Map.put(run.extensions, Reservations.key(), Ecto.UUID.generate())
    )
    |> Repo.update!()

    assert {:error, :fanout_child_scope_unavailable} =
             PlanFanout.dispatch_ready(
               c.goal.id,
               Keyword.put(c.opts, :admission_fun, fn _, _, _, _ ->
                 flunk("admission from unknown ownership")
               end)
             )

    assert length(Reservations.outstanding()) == 2
    assert Repo.aggregate(RunRecord, :count) == 2
  end

  test "a later completed sibling is accepted while the earlier child is still unresolved" do
    c = unit_fixture()
    assert {:ok, result} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
    [north, south] = result.dispatched
    complete_child!(c.goal, south.run_id)
    assert {:ok, %{reason: :fanout_coordinator_required}} = PlanExecutor.resume(c.goal.id, c.opts)
    assert {:ok, status} = PlanExecutor.status(c.goal.id, c.opts)
    assert status.accepted == ["south"]
    assert Enum.map(status.active_children, & &1.run_id) == [north.run_id]
    assert Enum.find(status.children, &(&1.plan_task_id == "south")).resolved?
    assert Repo.aggregate(RunRecord, :count) == 2
  end

  test "an exhausted sibling stays visible while another child remains active" do
    c =
      unit_fixture(
        transform_tasks: fn [north, south, join] ->
          north = put_in(north, ["execution", "max_attempts"], 1)
          [north, south, join]
        end
      )

    assert {:ok, result} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
    [north, south] = result.dispatched

    assert {:ok, _} =
             Shoestring.Trajectory.append(
               c.goal.id,
               %{
                 "type" => "run.failed",
                 "schema_version" => 1,
                 "actor" => "test",
                 "occurred_at" => PlanExecutorHelpers.now(),
                 "payload" => %{
                   "run_id" => north.run_id,
                   "error_category" => "transport",
                   "error_code" => "fixture_adapter_failure"
                 }
               },
               trusted: [run_id: north.run_id]
             )

    assert {:ok, %{retry_state: "escalate"}} =
             PlanExecutor.complete_task_run(c.goal.id, north.run_id, c.opts)

    assert {:ok, status} = PlanExecutor.status(c.goal.id, c.opts)
    assert status.needs_user?
    assert Enum.map(status.active_children, & &1.run_id) == [south.run_id]
    assert Enum.find(status.children, &(&1.run_id == north.run_id)).resolution == :gate_failed
    assert Enum.find(status.children, &(&1.run_id == north.run_id)).retry_state == "escalate"
  end

  test "dependent tasks require both acceptance gates and the approved input base" do
    c = unit_fixture()
    assert {:ok, result} = PlanFanout.dispatch_ready(c.goal.id, c.opts)

    for child <- result.dispatched do
      {:ok, tree} = Worktrees.get(child.run_id, c.opts)

      File.write!(
        Path.join(tree.path, "lib/#{child.plan_task_id}.ex"),
        "defmodule #{String.capitalize(child.plan_task_id)} do\n  def changed, do: true\nend\n"
      )

      git!(tree.path, ["add", "."])
      git!(tree.path, ["commit", "-m", "Retained sibling output"])
      complete_child!(c.goal, child.run_id)

      assert {:ok, %{disposition: :accepted}} =
               PlanExecutor.complete_task_run(c.goal.id, child.run_id, c.opts)
    end

    assert {:ok, %{accepted: ["north", "south"]}} = PlanExecutor.status(c.goal.id, c.opts)

    assert {:ok, result} =
             PlanFanout.dispatch_ready(
               c.goal.id,
               Keyword.put(c.opts, :admission_fun, fn _, _, _, _ ->
                 flunk("missing input integration")
               end)
             )

    assert result.dispatched == []
    assert [%{plan_task_id: "join", reason: :fanout_inputs_require_integration}] = result.blocked
    assert Repo.aggregate(RunRecord, :count) == 2

    assert {:error, :not_found} =
             Worktrees.get(PlanExecutor.task_run_id(c.goal.id, "join", 1), c.opts)

    assert git!(c.source, ["rev-parse", "HEAD"]) |> String.trim() == c.base

    # An approved amendment does not permit the ordinary sequential path to
    # discard accepted work from the other private branch.
    plan =
      Map.update!(c.plan, "tasks", fn [north, south, join] ->
        [north, south, Map.put(join, "outcome", "Join the accepted outputs after review")]
      end)

    assert {:ok, %{revision: revision}} =
             Shoestring.Cobbler.Plans.propose(
               c.goal.id,
               Shoestring.Test.PlanFixtures.propose_attrs(
                 plan: plan,
                 proposal_id: "join-amendment",
                 parent_revision_number: 1
               ),
               now: PlanExecutorHelpers.now()
             )

    assert {:ok, _} =
             Shoestring.Cobbler.Plans.approve(
               c.goal.id,
               Shoestring.Test.PlanFixtures.approve_attrs(2, revision.digest,
                 decision_id: "join-approval"
               ),
               now: PlanExecutorHelpers.now()
             )

    assert {:ok, _} =
             PlanExecutor.request_execution(
               c.goal.id,
               %{
                 revision_number: 2,
                 digest: revision.digest,
                 admission_event_id: admission!(c.goal).id
               },
               c.opts
             )

    assert {:error, :accepted_commit_not_integrated} = PlanExecutor.advance(c.goal.id, c.opts)
    assert Repo.aggregate(RunRecord, :count) == 2
  end

  test "failure of one intent transaction does not roll back an earlier sibling" do
    c = unit_fixture()

    Ecto.Adapters.SQL.query!(
      Repo,
      "CREATE TEMP TRIGGER reject_south BEFORE INSERT ON trajectory_events WHEN NEW.type = 'cobbler.plan.task.dispatched' AND json_extract(NEW.payload, '$.plan_task_id') = 'south' BEGIN SELECT RAISE(ABORT, 'fixture sibling abort'); END"
    )

    assert_raise Exqlite.Error, fn -> PlanFanout.dispatch_ready(c.goal.id, c.opts) end
    assert PlanExecutorHelpers.run_count(c.goal.id) == 1
    assert Repo.aggregate(ReservationRecord, :count) == 1
    assert Repo.aggregate(DispatchRecord, :count) == 1
    assert Repo.aggregate(Oban.Job, :count) == 1

    assert {:ok, %{active_task: "north", total_attempts: 1}} =
             PlanExecutor.status(c.goal.id, c.opts)
  end

  test "late effect admission still rechecks approval and reserved ownership" do
    c = unit_fixture()
    assert {:ok, result} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
    [north, south] = result.dispatched
    assert {:ok, _} = Projector.project(c.goal.id)

    assert {:ok, {:execute, _, _}} =
             Dispatches.prepare_for_effect(Repo.get!(RunRecord, north.run_id).dispatch_id)

    assert {:ok, _} =
             Reservations.require_reconciliation(south.reservation_id, "fixture uncertainty")

    assert {:error, :reservation_requires_reconciliation} =
             Dispatches.prepare_for_effect(Repo.get!(RunRecord, south.run_id).dispatch_id)

    assert Repo.aggregate(
             from(e in TrajectoryEvent, where: e.type == "cobbler.plan.task.dispatched"),
             :count
           ) == 2
  end

  defp unit_fixture(opts \\ []) do
    fixture(Keyword.put(opts, :reconciliation_opts, group_probe: fn _ -> :absent end))
  end
end
