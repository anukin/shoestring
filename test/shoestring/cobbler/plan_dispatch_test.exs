defmodule Shoestring.Cobbler.PlanDispatchTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.Cobbler.{
    Commands,
    PlanExecutor,
    ReservationPolicy,
    ReservationRecord,
    Reservations,
    TaskClaimRecord
  }

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
    revision = PlanExecutorHelpers.propose_and_approve!(goal)
    admission = admission!(goal)
    {:ok, policy} = ReservationPolicy.new()

    opts =
      PlanExecutorHelpers.exec_opts(
        clock: PlanHandoffClock,
        admission_event_id: admission.id,
        reservation_policy: policy
      )

    assert {:ok, _} =
             PlanExecutor.request_execution(
               goal.id,
               Map.put(revision, :admission_event_id, admission.id),
               opts
             )

    %{goal: goal, admission: admission, opts: opts}
  end

  defp admission!(goal) do
    snapshot_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, snapshot_id)

    payload =
      CobblerHelpers.admission_payload(
        provider_id: "fake",
        adapter_id: Fake.identity().adapter_id
      )
      |> Map.merge(%{
        "evaluated_at" => DateTime.to_iso8601(@now),
        "observation" => %{
          "snapshot_id" => snapshot_id,
          "confidence" => "high",
          "freshness" => "fresh"
        },
        "proposed_bounds" => %{
          "response_budget" => 10,
          "tool_budget" => 25,
          "checkpoint_cadence" => 1,
          "reserves" => %{"response" => 1, "tool" => 1},
          "deadline" => DateTime.to_iso8601(DateTime.add(@now, 300))
        }
      })

    CobblerHelpers.append_admission_event!(goal.id, payload)
  end

  test "approved ready task commits reservation, claim, lease, run, job and canonical delivery together",
       c do
    parent = self()

    opts =
      Keyword.put(c.opts, :publish_fun, fn event ->
        assert Repo.get!(TrajectoryEvent, event.id) == event
        send(parent, {:published, event.id})
      end)

    assert {:ok, result} = PlanExecutor.advance(c.goal.id, opts)
    assert result.disposition == :dispatched
    reservation = Repo.get!(ReservationRecord, result.reservation_id)
    run = Repo.get!(RunRecord, result.run_id)
    dispatch = Repo.get!(DispatchRecord, run.dispatch_id)
    assert Repo.get!(Oban.Job, dispatch.job_id).args["run_id"] == run.id
    assert run.extensions[Reservations.key()] == reservation.id
    assert reservation.admission_event_id == c.admission.id

    assert reservation.execution_id ==
             run.extensions[Shoestring.Cobbler.PlanBinding.key()]["execution_id"]

    assert reservation.lease_bounds == c.admission.payload["proposed_bounds"]
    assert Commands.active_claim().goal_id == c.goal.id
    types = Enum.map(result.dispatch_events, & &1.type)

    for type <-
          ~w(cobbler.claim.acquired run.requested lease.proposed lease.granted lease.active dispatch.requested cobbler.plan.task.dispatched),
        do: assert(type in types)

    assert {:ok, _} = Projector.project(c.goal.id, clock: PlanHandoffClock)
    lease = Repo.get!(ExecutionLeaseRecord, result.grant_id)
    assert lease.run_id == run.id
    assert lease.admitted_snapshot_id == reservation.snapshot_id

    assert {:ok, {:execute, _, _}} =
             Dispatches.prepare_for_effect(run.dispatch_id, clock: PlanHandoffClock)

    assert Repo.aggregate(ReservationRecord, :count) == 1
  end

  for phase <- ~w(run.requested lease.active dispatch.requested cobbler.plan.task.dispatched) do
    test "database abort at #{phase} rolls back every intent and emits no notification", c do
      # Trigger injection exercises the real insert boundary after earlier
      # writes, without modifying assertions or production failure handling.
      Ecto.Adapters.SQL.query!(
        Repo,
        "CREATE TEMP TRIGGER reject_dispatch_phase BEFORE INSERT ON trajectory_events WHEN NEW.type = '#{unquote(phase)}' BEGIN SELECT RAISE(ABORT, 'fixture dispatch abort'); END"
      )

      before_events = Repo.aggregate(TrajectoryEvent, :count)
      parent = self()
      opts = Keyword.put(c.opts, :publish_fun, fn event -> send(parent, {:published, event}) end)

      error =
        try do
          PlanExecutor.advance(c.goal.id, opts)
        rescue
          error -> error
        end

      assert Exception.message(error) =~ "fixture dispatch abort"

      for schema <- [
            ReservationRecord,
            RunRecord,
            DispatchRecord,
            ExecutionLeaseRecord,
            TaskClaimRecord,
            Task,
            Oban.Job
          ] do
        assert Repo.aggregate(schema, :count) == 0
      end

      assert Repo.aggregate(TrajectoryEvent, :count) == before_events
      assert Commands.active_claim() == nil
      refute_received {:published, _}
    end
  end

  test "a later failure restores the previous owned claim", c do
    assert {:ok, _} =
             Commands.submit(
               c.goal.id,
               CobblerHelpers.claim_command(c.admission, command_id: "prior-claim"),
               now: @now
             )

    prior = Commands.active_claim()

    Ecto.Adapters.SQL.query!(
      Repo,
      "CREATE TEMP TRIGGER reject_dispatch_phase BEFORE INSERT ON trajectory_events WHEN NEW.type = 'lease.active' BEGIN SELECT RAISE(ABORT, 'fixture dispatch abort'); END"
    )

    assert_raise Exqlite.Error, fn -> PlanExecutor.advance(c.goal.id, c.opts) end
    assert Commands.active_claim() == prior
    assert Repo.aggregate(ReservationRecord, :count) == 0
    assert Repo.aggregate(RunRecord, :count) == 0
  end

  test "capacity refusal writes no claim, run, lease or job and preserves the unrelated owner",
       c do
    other = CobblerHelpers.create_goal!()
    admission = admission!(other)
    {:ok, policy} = ReservationPolicy.new()

    attrs = %{
      id: Ecto.UUID.generate(),
      goal_id: other.id,
      execution_id: Ecto.UUID.generate(),
      plan_task_id: "other",
      attempt: 1,
      run_id: Ecto.UUID.generate(),
      admission_event_id: admission.id
    }

    assert {:ok, reservation} = Reservations.hold(attrs, policy, now: @now)
    before_events = Repo.aggregate(TrajectoryEvent, :count)

    assert {:error, {:reservation_blocked, :global_limit}} =
             PlanExecutor.advance(c.goal.id, c.opts)

    assert Reservations.outstanding() == [reservation]

    for schema <- [RunRecord, DispatchRecord, ExecutionLeaseRecord, TaskClaimRecord, Oban.Job],
        do: assert(Repo.aggregate(schema, :count) == 0)

    assert Repo.aggregate(TrajectoryEvent, :count) == before_events
  end

  test "repeated advance and projection reconstruction do not duplicate reservation or delivery",
       c do
    assert {:ok, first} = PlanExecutor.advance(c.goal.id, c.opts)
    assert {:ok, %{disposition: :awaiting_task}} = PlanExecutor.advance(c.goal.id, c.opts)
    assert {:ok, _} = Projector.rebuild(c.goal.id, clock: PlanHandoffClock)
    assert {:ok, %{disposition: :awaiting_task}} = PlanExecutor.resume(c.goal.id, c.opts)
    assert Repo.aggregate(ReservationRecord, :count) == 1
    assert Repo.aggregate(RunRecord, :count) == 1
    assert Repo.aggregate(DispatchRecord, :count) == 1
    assert Repo.aggregate(Oban.Job, :count) == 1
    assert Reservations.outstanding() |> hd() |> Map.fetch!(:run_id) == first.run_id
  end

  test "missing, wrong and uncertain reservation bindings refuse effect admission", c do
    assert {:ok, result} = PlanExecutor.advance(c.goal.id, c.opts)
    run = Repo.get!(RunRecord, result.run_id)
    missing = %{run | id: Ecto.UUID.generate()}
    assert {:error, :reservation_missing} = Reservations.authorize(Repo, missing)
    wrong = %{run | extensions: Map.put(run.extensions, Reservations.key(), Ecto.UUID.generate())}
    assert {:error, :reservation_binding_mismatch} = Reservations.authorize(Repo, wrong)
    binding_key = Shoestring.Cobbler.PlanBinding.key()

    for {key, value} <- [
          {"execution_id", Ecto.UUID.generate()},
          {"plan_task_id", "beta"},
          {"attempt", 2}
        ] do
      forged = %{
        run
        | extensions: Map.update!(run.extensions, binding_key, &Map.put(&1, key, value))
      }

      assert {:error, :reservation_binding_mismatch} = Reservations.authorize(Repo, forged)
    end

    assert {:ok, _} =
             Reservations.require_reconciliation(result.reservation_id, "operator uncertainty",
               now: @now
             )

    assert {:error, :reservation_requires_reconciliation} =
             Dispatches.prepare_for_effect(run.dispatch_id, clock: PlanHandoffClock)

    assert Repo.get!(DispatchRecord, run.dispatch_id).status == "requested"
  end

  test "invalid operator policy fails closed before dispatch", c do
    assert {:error, _} =
             PlanExecutor.advance(
               c.goal.id,
               Keyword.put(c.opts, :reservation_policy, %{global_limit: 0})
             )

    assert Repo.aggregate(ReservationRecord, :count) == 0
    assert Repo.aggregate(RunRecord, :count) == 0
  end

  test "an enclosing transaction can roll back the whole dispatch without publishing", c do
    parent = self()
    opts = Keyword.put(c.opts, :publish_fun, fn event -> send(parent, {:published, event}) end)
    before_events = Repo.aggregate(TrajectoryEvent, :count)

    assert {:error, :outer_abort} =
             Repo.transaction(fn ->
               assert {:ok, result} = PlanExecutor.advance(c.goal.id, opts)
               assert result.dispatch_events != []
               assert Repo.aggregate(ReservationRecord, :count) == 1
               refute_received {:published, _}
               Repo.rollback(:outer_abort)
             end)

    for schema <- [
          ReservationRecord,
          RunRecord,
          DispatchRecord,
          ExecutionLeaseRecord,
          TaskClaimRecord,
          Task,
          Oban.Job
        ],
        do: assert(Repo.aggregate(schema, :count) == 0)

    assert Repo.aggregate(TrajectoryEvent, :count) == before_events
    refute_received {:published, _}
  end

  test "transaction-local append refuses a caller without a transaction", c do
    before_events = Repo.aggregate(TrajectoryEvent, :count)

    assert {:error, :trajectory_transaction_required} =
             Shoestring.Trajectory.append(
               c.goal.id,
               %{
                 "type" => "run.completed",
                 "schema_version" => 1,
                 "actor" => "fixture",
                 "occurred_at" => @now,
                 "payload" => %{"run_id" => Ecto.UUID.generate()}
               },
               writer_opts: [transaction_repo: Repo]
             )

    assert Repo.aggregate(TrajectoryEvent, :count) == before_events
  end

  test "approval changed after task selection refuses the atomic dispatch", c do
    admission = fn _, _, _, _ ->
      plan =
        PlanExecutorHelpers.chain_plan()
        |> Map.update!("tasks", fn [first | rest] ->
          [Map.put(first, "outcome", "A changed approved outcome.") | rest]
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

      {:ok, c.admission.id}
    end

    assert {:error, {:lease_run_failed, :plan_authority_changed}} =
             PlanExecutor.advance(c.goal.id, Keyword.put(c.opts, :admission_fun, admission))

    for schema <- [
          ReservationRecord,
          RunRecord,
          DispatchRecord,
          ExecutionLeaseRecord,
          TaskClaimRecord,
          Task,
          Oban.Job
        ],
        do: assert(Repo.aggregate(schema, :count) == 0)
  end
end
