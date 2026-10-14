defmodule Shoestring.Cobbler.ReservationDispatchTest do
  @moduledoc "New-capability checks for the internal atomic boundary, not production fan-out."
  use Shoestring.DataCase, async: false
  alias Shoestring.Cobbler.{Commands, Dispatcher, PlanBinding, PlanDispatch, PlanExecutor}
  alias Shoestring.Cobbler.{ReservationPolicy, ReservationRecord, Reservations, TaskClaimRecord}

  alias Shoestring.Harness.{
    Dispatches,
    DispatchRecord,
    ExecutionLeaseRecord,
    Fake,
    Projector,
    RunRecord
  }

  alias Shoestring.Test.{CobblerHelpers, PlanExecutorHelpers, PlanHandoffClock}
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Trajectory.{Task, TrajectoryEvent}
  @now PlanExecutorHelpers.now()

  setup do
    goal = CobblerHelpers.create_goal!()

    revision =
      PlanExecutorHelpers.propose_and_approve!(goal, PlanExecutorHelpers.independent_plan())

    admission = admission!(goal)

    opts =
      PlanExecutorHelpers.exec_opts(clock: PlanHandoffClock, admission_event_id: admission.id)

    assert {:ok, %{execution: execution}} =
             PlanExecutor.request_execution(
               goal.id,
               Map.put(revision, :admission_event_id, admission.id),
               opts
             )

    {:ok, policy} =
      ReservationPolicy.new(%{
        global_limit: 2,
        provider_account_limit: 2,
        goal_limit: 2,
        account_units: 2
      })

    %{goal: goal, revision: revision, execution: execution, policy: policy}
  end

  defp admission!(goal, changes \\ %{}) do
    snapshot = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, snapshot)

    payload =
      CobblerHelpers.admission_payload(
        provider_id: "fake",
        adapter_id: Fake.identity().adapter_id
      )
      |> Map.merge(%{
        "evaluated_at" => DateTime.to_iso8601(@now),
        "observation" => %{
          "snapshot_id" => snapshot,
          "confidence" => "high",
          "freshness" => "fresh"
        },
        "proposed_bounds" => %{
          "response_budget" => 10,
          "tool_budget" => 25,
          "reserves" => %{"response" => 1, "tool" => 1},
          "checkpoint_cadence" => 1,
          "deadline" => DateTime.to_iso8601(DateTime.add(@now, 300))
        }
      })
      |> Map.merge(changes)

    CobblerHelpers.append_admission_event!(goal.id, payload)
  end

  defp candidate(c, task_id, admission \\ nil) do
    admission = admission || admission!(c.goal)
    task = %Task{goal_id: c.goal.id} |> Task.changeset(%{title: task_id}) |> Repo.insert!()

    owner = %{
      id: Ecto.UUID.generate(),
      goal_id: c.goal.id,
      execution_id: c.execution.execution_id,
      plan_task_id: task_id,
      attempt: 1,
      run_id: PlanExecutor.task_run_id(c.goal.id, task_id, 1),
      admission_event_id: admission.id
    }

    lease = [
      task_id: task.id,
      run_id: owner.run_id,
      dispatch_id: Ecto.UUID.generate(),
      workspace_ref: "fixture/#{task_id}",
      repo: Repo,
      now: @now,
      clock: PlanHandoffClock,
      extensions: %{
        Reservations.key() => owner.id,
        PlanBinding.key() => %{
          "execution_id" => c.execution.execution_id,
          "revision_number" => c.revision.revision_number,
          "plan_digest" => c.revision.digest,
          "plan_task_id" => task_id,
          "attempt" => 1
        }
      }
    ]

    %{owner: owner, attrs: CobblerHelpers.claim_command(admission), lease: lease}
  end

  defp dispatch(c, candidate, extra \\ []) do
    opts =
      Keyword.merge(
        [repo: Repo, now: @now, clock: PlanHandoffClock, reservation_policy: c.policy],
        extra
      )

    PlanDispatch.run(candidate.owner, opts, fn opts ->
      Dispatcher.claim_reserved_and_gate(
        c.goal.id,
        candidate.attrs,
        candidate.owner.id,
        Keyword.put(opts, :grant_lease, candidate.lease)
      )
    end)
  end

  test "two children hold distinct commands, runs, leases and deliveries without a global claim",
       c do
    north = candidate(c, "north")
    south = candidate(c, "south")
    assert {:ok, first} = dispatch(c, north)
    assert {:ok, second} = dispatch(c, south)
    assert first.reservation_id != second.reservation_id
    refute Map.has_key?(first, :claim_id)
    assert Commands.active_claim() == nil
    assert Repo.aggregate(TaskClaimRecord, :count) == 0

    for schema <- [ReservationRecord, RunRecord, DispatchRecord, Oban.Job],
        do: assert(Repo.aggregate(schema, :count) == 2)

    assert {:ok, _} = Projector.project(c.goal.id, clock: PlanHandoffClock)
    assert Repo.aggregate(ExecutionLeaseRecord, :count) == 2

    for child <- [first, second] do
      assert child.disposition == :leased
      assert child.run.id == child.lease.run_id
      assert child.command.result["run_id"] == child.run.id

      assert {:ok, {:execute, _, _}} =
               Dispatches.prepare_for_effect(child.run.dispatch_id, clock: PlanHandoffClock)
    end

    assert {:ok, %{consistent?: true}} = Commands.rebuild(c.goal.id)
  end

  test "operator cap refuses the second child atomically", c do
    {:ok, policy} = ReservationPolicy.new()
    c = %{c | policy: policy}
    north = candidate(c, "north")
    south = candidate(c, "south")
    assert {:ok, _} = dispatch(c, north)
    before = Repo.aggregate(TrajectoryEvent, :count)
    assert {:error, {:reservation_blocked, :global_limit}} = dispatch(c, south)
    assert Repo.aggregate(TrajectoryEvent, :count) == before
    assert Repo.get(ReservationRecord, south.owner.id) == nil
    assert Commands.get(c.goal.id, south.attrs["command_id"]) == nil
    assert Repo.aggregate(DispatchRecord, :count) == 1
  end

  test "configured goal and global limits apply across distinct goals", c do
    other = CobblerHelpers.create_goal!()

    revision =
      PlanExecutorHelpers.propose_and_approve!(other, PlanExecutorHelpers.independent_plan())

    admission = admission!(other)

    assert {:ok, %{execution: execution}} =
             PlanExecutor.request_execution(
               other.id,
               Map.put(revision, :admission_event_id, admission.id),
               PlanExecutorHelpers.exec_opts(
                 clock: PlanHandoffClock,
                 admission_event_id: admission.id
               )
             )

    {:ok, policy} =
      ReservationPolicy.new(%{
        global_limit: 2,
        goal_limit: 1,
        provider_account_limit: 2,
        account_units: 2
      })

    c = %{c | policy: policy}
    foreign = %{c | goal: other, revision: revision, execution: execution}
    first = candidate(c, "north")
    second = candidate(c, "south")
    third = candidate(foreign, "north")
    fourth = candidate(foreign, "south")
    assert {:ok, _} = dispatch(c, first)
    assert {:error, {:reservation_blocked, :goal_limit}} = dispatch(c, second)
    assert {:ok, _} = dispatch(foreign, third)
    assert {:error, {:reservation_blocked, :global_limit}} = dispatch(foreign, fourth)
    assert length(Reservations.outstanding()) == 2
    assert Commands.active_claim() == nil
    assert Repo.aggregate(Oban.Job, :count) == 2
  end

  test "even a same-goal legacy claim prevents reservation-owned dispatch", c do
    admission = admission!(c.goal)

    assert {:ok, _} =
             Commands.submit(c.goal.id, CobblerHelpers.claim_command(admission), now: @now)

    prior = Commands.active_claim()
    child = candidate(c, "north")
    assert {:error, :reservation_claim_unavailable} = dispatch(c, child)
    assert Commands.active_claim() == prior
    assert Repo.aggregate(ReservationRecord, :count) == 0
    assert Repo.aggregate(RunRecord, :count) == 0
  end

  test "a reserved result cannot grant goal-wide direct dispatch authority", c do
    child = candidate(c, "north")
    assert {:ok, first} = dispatch(c, child)
    assert {:error, _} = Shoestring.Cobbler.DispatchGate.authorize(c.goal.id)

    assert {:error, {:no_claimed_command, _}} =
             Dispatcher.dispatch(c.goal.id, first.command.command_id, grant_lease: child.lease)

    assert Repo.aggregate(RunRecord, :count) == 1
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "identical replay and projection rebuild create no additional intent", c do
    child = candidate(c, "north")
    assert {:ok, first} = dispatch(c, child)
    assert {:ok, _} = Projector.rebuild(c.goal.id, clock: PlanHandoffClock)
    before = Repo.aggregate(TrajectoryEvent, :count)
    assert {:ok, replay} = dispatch(c, child)
    assert replay.outcome == :replayed
    assert replay.lease_outcome == :replayed
    assert replay.grant_id == first.grant_id
    assert replay.run == nil and replay.dispatch == nil and replay.job == nil
    assert Repo.aggregate(TrajectoryEvent, :count) == before
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  for phase <- ~w(run.requested lease.active dispatch.requested) do
    test "failure at #{phase} rolls back owner, command, run and delivery", c do
      child = candidate(c, "north")

      Ecto.Adapters.SQL.query!(
        Repo,
        "CREATE TEMP TRIGGER reject_reserved BEFORE INSERT ON trajectory_events WHEN NEW.type = '#{unquote(phase)}' BEGIN SELECT RAISE(ABORT, 'fixture reserved abort'); END"
      )

      before = Repo.aggregate(TrajectoryEvent, :count)
      parent = self()

      assert_raise Exqlite.Error, fn ->
        dispatch(c, child, publish_fun: fn event -> send(parent, {:published, event}) end)
      end

      for schema <- [ReservationRecord, RunRecord, DispatchRecord, TaskClaimRecord, Oban.Job],
          do: assert(Repo.aggregate(schema, :count) == 0)

      assert Commands.get(c.goal.id, child.attrs["command_id"]) == nil
      assert Repo.aggregate(TrajectoryEvent, :count) == before
      refute_received {:published, _}
    end
  end

  test "malformed run and task bindings refuse before run creation", c do
    original = candidate(c, "north")

    for {key, value} <- [
          run_id: Ecto.UUID.generate(),
          extensions: %{},
          task_id: Ecto.UUID.generate()
        ] do
      child = %{original | lease: Keyword.put(original.lease, key, value)}
      assert {:error, _} = dispatch(c, child)
      assert Repo.get(ReservationRecord, child.owner.id) == nil
      assert Repo.aggregate(RunRecord, :count) == 0
    end

    child = %{original | owner: %{original.owner | execution_id: Ecto.UUID.generate()}}
    assert {:error, :reservation_grant_binding_mismatch} = dispatch(c, child)
  end

  test "uncertain owners cannot re-gate a recorded command", c do
    child = candidate(c, "north")
    assert {:ok, first} = dispatch(c, child)

    assert {:ok, _} =
             Reservations.require_reconciliation(child.owner.id, "fixture uncertainty", now: @now)

    assert {:error, :reservation_claim_unavailable} = dispatch(c, child)
    assert Repo.get!(RunRecord, first.run.id).status == "requested"
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "settled never-started ownership cannot be revived by replay", c do
    child = candidate(c, "north")
    assert {:ok, first} = dispatch(c, child)
    owner = Repo.get!(ReservationRecord, child.owner.id)

    assert {:ok, %{settlement: %{kind: "released"}}} =
             Repo.transaction(fn ->
               Shoestring.Cobbler.ReservationRecovery.cancel_unstarted(
                 owner,
                 Ecto.UUID.generate(),
                 repo: Repo,
                 now: @now,
                 elf_lookup: fn _ -> nil end
               )
             end)

    assert {:error, :reservation_settled} = dispatch(c, child)
    assert Repo.get!(DispatchRecord, first.run.dispatch_id).status == "cancelled"
    assert Repo.aggregate(RunRecord, :count) == 1
  end

  test "missing or wrong admission and goal cannot claim another owner", c do
    child = candidate(c, "north")
    wrong_admission = admission!(c.goal)
    wrong = %{child | attrs: CobblerHelpers.claim_command(wrong_admission)}
    assert {:error, :reservation_claim_unavailable} = dispatch(c, wrong)
    other = CobblerHelpers.create_goal!()
    assert {:error, :reservation_claim_unavailable} = dispatch(%{c | goal: other}, child)
    assert Repo.aggregate(ReservationRecord, :count) == 0
    assert Repo.aggregate(RunRecord, :count) == 0
  end

  test "current approval is required at the intent boundary", c do
    child = candidate(c, "north")

    plan =
      PlanExecutorHelpers.independent_plan()
      |> Map.update!("tasks", fn [first, second] ->
        [Map.put(first, "outcome", "Changed outcome"), second]
      end)

    assert {:ok, %{revision: revision}} =
             Shoestring.Cobbler.Plans.propose(
               c.goal.id,
               Shoestring.Test.PlanFixtures.propose_attrs(
                 plan: plan,
                 proposal_id: "changed",
                 parent_revision_number: 1
               ),
               now: @now
             )

    assert {:ok, _} =
             Shoestring.Cobbler.Plans.approve(
               c.goal.id,
               Shoestring.Test.PlanFixtures.approve_attrs(2, revision.digest,
                 decision_id: "changed-approval"
               ),
               now: @now
             )

    assert {:error, :reservation_grant_binding_mismatch} = dispatch(c, child)
    assert Repo.aggregate(ReservationRecord, :count) == 0
    assert Repo.aggregate(RunRecord, :count) == 0
  end

  test "missing lease and transaction fail without creating a command", c do
    child = candidate(c, "north")
    refute Repo.in_transaction?()

    assert {:error, :reservation_transaction_required} =
             Dispatcher.claim_reserved_and_gate(c.goal.id, child.attrs, child.owner.id,
               grant_lease: child.lease
             )

    assert {:error, :reservation_transaction_required} =
             Commands.submit_reserved(c.goal.id, child.attrs, child.owner.id, [])

    assert {:error, :reservation_lease_required} =
             PlanDispatch.run(
               child.owner,
               [repo: Repo, now: @now, reservation_policy: c.policy],
               fn opts ->
                 Dispatcher.claim_reserved_and_gate(c.goal.id, child.attrs, child.owner.id, opts)
               end
             )

    assert Commands.get(c.goal.id, child.attrs["command_id"]) == nil
    assert Repo.aggregate(ReservationRecord, :count) == 0
  end

  test "canonical result prevents swapping a cached command to another valid owner", c do
    north = candidate(c, "north")
    south = candidate(c, "south")
    assert {:ok, first} = dispatch(c, north)
    assert {:ok, second} = dispatch(c, south)
    # Copy all digest-covered intent fields and the otherwise valid sibling
    # result. The original canonical event still belongs to the first child.
    first.command
    |> Ecto.Changeset.change(
      payload: second.command.payload,
      digest: second.command.digest,
      result: second.command.result
    )
    |> Repo.update!()

    swapped = %{south | attrs: Map.put(south.attrs, "command_id", north.attrs["command_id"])}
    assert {:error, :reservation_command_not_canonical} = dispatch(c, swapped)
    assert Repo.aggregate(RunRecord, :count) == 2
  end

  test "replay cannot change the run's workspace or delivery identity", c do
    child = candidate(c, "north")
    assert {:ok, first} = dispatch(c, child)

    for {key, value} <- [workspace_ref: "fixture/foreign", dispatch_id: Ecto.UUID.generate()] do
      assert {:error, :reservation_run_replay_mismatch} =
               dispatch(c, %{child | lease: Keyword.put(child.lease, key, value)})
    end

    assert Repo.get!(RunRecord, first.run.id).workspace_ref == "fixture/north"
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "a second command cannot claim the same owner", c do
    child = candidate(c, "north")
    assert {:ok, _} = dispatch(c, child)
    other = %{child | attrs: Map.put(child.attrs, "command_id", "other-reserved-command")}
    assert {:error, :reservation_command_already_bound} = dispatch(c, other)
    assert Commands.get(c.goal.id, "other-reserved-command") == nil
  end

  test "repeated admission decision identity cannot share a sibling lease", c do
    admission = admission!(c.goal)
    first = candidate(c, "north", admission)
    assert {:ok, _} = dispatch(c, first)
    second_admission = admission!(c.goal, %{"decision_id" => admission.payload["decision_id"]})
    second = candidate(c, "south", second_admission)
    assert {:error, :reservation_admission_already_bound} = dispatch(c, second)
    assert Repo.get(ReservationRecord, second.owner.id) == nil
    assert Repo.aggregate(RunRecord, :count) == 1
  end

  test "changed command cache cannot replace canonical reservation authority", c do
    child = candidate(c, "north")
    assert {:ok, first} = dispatch(c, child)

    first.command
    |> Ecto.Changeset.change(
      result: Map.put(first.command.result, "run_id", Ecto.UUID.generate())
    )
    |> Repo.update!()

    assert {:error, :reservation_command_mismatch} = dispatch(c, child)
    assert Repo.aggregate(RunRecord, :count) == 1
  end

  test "generic command and inspection paths do not enable reservation dispatch", c do
    child = candidate(c, "north")
    assert {:ok, _} = Reservations.hold(child.owner, c.policy, now: @now)

    assert {:ok, %{disposition: :command_rejected}} =
             Dispatcher.claim_and_gate(c.goal.id, child.attrs, grant_lease: child.lease)

    assert Repo.aggregate(RunRecord, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
  end
end
