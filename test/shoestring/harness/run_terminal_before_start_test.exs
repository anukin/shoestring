defmodule Shoestring.Harness.RunTerminalBeforeStartTest do
  @moduledoc """
  A run that ends before it ever starts must still project.

  Two production paths reach a terminal from a `requested` run row:

    * `Shoestring.Elves.Elf.launch_fresh/1` commits `run.failed` when the
      launch aborts BEFORE `run.starting` could be appended (the `with`'s
      first clause is the `run.starting` append itself, so its failure lands
      in the same else-branch as every later one);
    * `Shoestring.Elves.cancel_run/2` on a run with no live Elf appends
      `run.cancelling` / `run.cancelled` through `append_cancelled/2`, which
      does not consult the row's state.

  Before the fix `Shoestring.Harness.RunStateMachine` had no
  `requested --fail-->` or `requested --cancel-->` edge, so the projector
  rejected the Elf's own terminal as an illegal transition AND LEFT THE
  GOAL'S PROJECTOR POSITION `failed`. Nothing else for that goal projected
  after it — not other runs, not checkpoints, not leases. A terminal the
  projector can never apply is worse than a missing terminal.

  Observed live on the first receiver leg of the 2026-09-21 verification;
  see `plans/evidence/05-quota-aware-mvp/live-cross-provider-handoff.md`
  §7.3.

  ## Lock-vs-documentation ledger

  Measured against base `6f1653fed931d120d463676ec40e95e6b8ad7327`.

  **TRUE behavioural locks — 5 of the 6 tests here.** On base the suite
  reports `6 tests, 5 failures`:

    * all three projection tests fail with the projector returning
      `{:harness_projection_failed, _, %Error{code:
      "run_transition_rejected"}, _}` where they assert `{:ok, position}`.
      The third of them, `"a goal keeps projecting after a pre-start
      terminal"`, locks the *consequence* rather than a second defect: on
      base a later, entirely valid run of the same goal never projects
      either, because the position stalled on the bad event;
    * `"a requested run may fail"` and `"a requested run may be cancelled"`
      fail with `{:error, %Error{code: "run_transition_rejected"}}` from
      `RunStateMachine.transition/2`.

  **DOCUMENTATION, not a lock:** `"a requested run still may not complete,
  interrupt, or start twice"` passes on base. It is the negative control
  that keeps the two new edges from being read as "anything goes from
  `requested`".

  **Deliberately absent:** no `requested --interrupt-->` row. No production
  path was found that emits `run.interrupted` for a run that never started,
  and a test for an edge with no producer would assert a shape the system
  cannot reach.
  """
  use Shoestring.DataCase, async: false

  import Ecto.Query

  alias Shoestring.Harness.{Error, Projector, RunRecord, RunStateMachine}
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{ProjectorPosition, TrajectoryEvent}

  @t0 ~U[2026-09-21 12:00:00.000000Z]

  describe "RunStateMachine" do
    test "a requested run may fail" do
      assert {:ok, %{state: :failed}} = RunStateMachine.transition(:requested, :fail)
    end

    test "a requested run may be cancelled" do
      assert {:ok, %{state: :cancelling}} = RunStateMachine.transition(:requested, :cancel)
      assert {:ok, %{state: :cancelled}} = RunStateMachine.transition(:cancelling, :cancelled)
    end

    test "a requested run still may not complete, interrupt, or start twice" do
      for event <- [:complete, :interrupt, :started] do
        assert {:error, %Error{code: "run_transition_rejected"}} =
                 RunStateMachine.transition(:requested, event)
      end
    end
  end

  describe "projection of a terminal that arrives before run.starting" do
    test "a launch failure before run.starting projects to failed" do
      fixture = fixture()

      append!(fixture, "run.failed", "elf-terminal:", %{
        "run_id" => fixture.run.id,
        "error_category" => "transport",
        "error_code" => "process_launch_failed"
      })

      assert {:ok, %ProjectorPosition{status: "ok"}} = Projector.project(fixture.goal.id)
      assert Repo.get!(RunRecord, fixture.run.id).status == "failed"
    end

    test "a cancellation before run.starting projects to cancelled" do
      fixture = fixture()

      append!(fixture, "run.cancelling", "elf-cancelling:", %{"run_id" => fixture.run.id})
      append!(fixture, "run.cancelled", "elf-terminal:", %{"run_id" => fixture.run.id})

      assert {:ok, %ProjectorPosition{status: "ok"}} = Projector.project(fixture.goal.id)
      assert Repo.get!(RunRecord, fixture.run.id).status == "cancelled"
    end

    test "a goal keeps projecting after a pre-start terminal" do
      fixture = fixture()

      append!(fixture, "run.failed", "elf-terminal:", %{
        "run_id" => fixture.run.id,
        "error_category" => "transport",
        "error_code" => "process_launch_failed"
      })

      # A second run of the same goal, appended AFTER the unprojectable
      # terminal. This is the consequence that made the defect severe: on
      # base the position stops at the bad event and this run never projects
      # at all.
      second =
        FakeHelpers.insert_run_record(fixture.goal, fixture.task, Ecto.UUID.generate(),
          run_id: Ecto.UUID.generate()
        )

      FakeHelpers.append_run_requested(fixture.goal, fixture.task, second)

      assert {:ok, %ProjectorPosition{status: "ok"}} = Projector.project(fixture.goal.id)
      assert Repo.get!(RunRecord, second.id).status == "requested"

      # And the position has consumed every event, not stalled on one.
      last = Repo.one!(from e in TrajectoryEvent, select: max(e.sequence))
      assert Repo.get_by!(ProjectorPosition, goal_id: fixture.goal.id).last_sequence == last
    end
  end

  defp fixture do
    goal = FakeHelpers.insert_goal(Ecto.UUID.generate())
    task = FakeHelpers.insert_task(goal, Ecto.UUID.generate())

    run =
      FakeHelpers.insert_run_record(goal, task, Ecto.UUID.generate(),
        run_id: Ecto.UUID.generate()
      )

    FakeHelpers.append_run_requested(goal, task, run)

    %{goal: goal, task: task, run: run}
  end

  defp append!(fixture, type, key_prefix, payload) do
    {:ok, event} =
      Trajectory.append(
        fixture.goal.id,
        %{
          "type" => type,
          "schema_version" => 1,
          "actor" => "elf",
          "occurred_at" => @t0,
          "idempotency_key" => "#{key_prefix}#{fixture.run.dispatch_id}",
          "payload" => payload
        },
        trusted: [task_id: fixture.task.id, run_id: fixture.run.id]
      )

    event
  end
end
