defmodule Shoestring.Cobbler.PlanExecutorTest do
  @moduledoc """
  Hermetic DataCase tests for durable sequential approved-plan execution.

  New functionality in this work package (absent at the base commit
  `df62479`): every test below exercises `Shoestring.Cobbler.PlanExecutor`
  through the `Shoestring.Cobbler` facade with Fake-grade admission and an
  injected gate runner. No provider CLI, no network, no OS gate processes.

  Integrity locks against demonstrated pre-existing gaps live in
  `plan_authority_hardening_test.exs`, which verifies they fail at the
  pre-fix commit for the right behavioural reason.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Cobbler
  alias Shoestring.Cobbler.{PlanExecutor, Plans}
  alias Shoestring.Test.CobblerHelpers
  alias Shoestring.Test.PlanExecutorHelpers
  alias Shoestring.Test.PlanFixtures

  import PlanExecutorHelpers,
    only: [
      admit!: 1,
      chain_plan: 0,
      chain_plan: 1,
      complete_run!: 2,
      exec_opts: 0,
      exec_opts: 1,
      gate_opts: 0,
      gate_opts: 1,
      independent_plan: 0,
      now: 0,
      propose_and_approve!: 1,
      propose_and_approve!: 2,
      run_count: 1
    ]

  setup do
    goal = CobblerHelpers.create_goal!()
    %{goal: goal}
  end

  defp request!(goal, rev, admission, extra \\ []) do
    assert {:ok, %{outcome: outcome} = result} =
             Cobbler.request_plan_execution(
               goal.id,
               %{
                 revision_number: rev.revision_number,
                 digest: rev.digest,
                 admission_event_id: admission.id
               },
               exec_opts(extra)
             )

    {outcome, result}
  end

  defp advance!(goal, extra) do
    assert {:ok, result} = Cobbler.advance_plan_execution(goal.id, exec_opts(extra))
    result
  end

  describe "authority binding at the dispatch boundary" do
    test "a proposed (unapproved) plan cannot dispatch", %{goal: goal} do
      assert {:ok, %{revision: revision}} =
               Plans.propose(goal.id, PlanFixtures.propose_attrs(plan: chain_plan()),
                 now: now(),
                 publish_fun: fn _event -> :ok end
               )

      admission = admit!(goal)

      assert {:error, :no_approved_authority} =
               Cobbler.request_plan_execution(
                 goal.id,
                 %{
                   revision_number: revision.revision_number,
                   digest: revision.digest,
                   admission_event_id: admission.id
                 },
                 exec_opts()
               )

      assert run_count(goal.id) == 0
    end

    test "a rejected plan cannot dispatch", %{goal: goal} do
      plan_opts = [now: now(), publish_fun: fn _event -> :ok end]

      assert {:ok, %{revision: revision}} =
               Plans.propose(goal.id, PlanFixtures.propose_attrs(plan: chain_plan()), plan_opts)

      assert {:ok, _} =
               Plans.reject(
                 goal.id,
                 PlanFixtures.reject_attrs(revision.revision_number, revision.digest),
                 plan_opts
               )

      admission = admit!(goal)

      assert {:error, :no_approved_authority} =
               Cobbler.request_plan_execution(
                 goal.id,
                 %{
                   revision_number: revision.revision_number,
                   digest: revision.digest,
                   admission_event_id: admission.id
                 },
                 exec_opts()
               )

      assert run_count(goal.id) == 0
    end

    test "a stale digest is refused", %{goal: goal} do
      rev = propose_and_approve!(goal)
      admission = admit!(goal)

      assert {:error, {:authority_mismatch, _detail}} =
               Cobbler.request_plan_execution(
                 goal.id,
                 %{
                   revision_number: rev.revision_number,
                   digest: String.duplicate("0", 64),
                   admission_event_id: admission.id
                 },
                 exec_opts()
               )

      assert run_count(goal.id) == 0
    end

    test "a cross-goal revision cannot authorize", %{goal: goal} do
      other = CobblerHelpers.create_goal!()
      foreign_rev = propose_and_approve!(other, independent_plan())
      _own_rev = propose_and_approve!(goal)
      admission = admit!(goal)

      assert {:error, {:authority_mismatch, _detail}} =
               Cobbler.request_plan_execution(
                 goal.id,
                 %{
                   revision_number: foreign_rev.revision_number,
                   digest: foreign_rev.digest,
                   admission_event_id: admission.id
                 },
                 exec_opts()
               )

      assert run_count(goal.id) == 0
    end

    test "an admission from another goal is refused", %{goal: goal} do
      rev = propose_and_approve!(goal)
      other = CobblerHelpers.create_goal!()
      foreign = admit!(other)

      assert {:error, {:admission_not_found, _id}} =
               Cobbler.request_plan_execution(
                 goal.id,
                 %{
                   revision_number: rev.revision_number,
                   digest: rev.digest,
                   admission_event_id: foreign.id
                 },
                 exec_opts()
               )
    end

    test "planning stays inert until an explicit execution request", %{goal: goal} do
      rev = propose_and_approve!(goal)
      _ = rev

      assert {:error, :no_execution_requested} =
               Cobbler.advance_plan_execution(goal.id, exec_opts())

      assert {:ok, %{planned?: false}} = Cobbler.plan_execution_status(goal.id)
      assert run_count(goal.id) == 0
    end
  end

  describe "sequential dependency execution" do
    test "a chain executes in order with one active task and no premature completion", %{
      goal: goal
    } do
      rev = propose_and_approve!(goal)
      first_admission = admit!(goal)
      assert :recorded = elem(request!(goal, rev, first_admission), 0)

      assert {:ok, %{planned?: true, completed?: false, accepted: []}} =
               Cobbler.plan_execution_status(goal.id)

      first = advance!(goal, admission_event_id: first_admission.id)
      assert first.disposition == :dispatched
      assert first.plan_task_id == "alpha"
      assert first.attempt == 1
      assert run_count(goal.id) == 1

      waiting = advance!(goal, admission_event_id: first_admission.id)
      assert waiting.disposition == :awaiting_task
      assert waiting.active_task == "alpha"
      assert run_count(goal.id) == 1

      # The run alone never completes the goal.
      complete_run!(goal, first.run_id)

      assert {:ok, completed} = Cobbler.complete_plan_task_run(goal.id, first.run_id, exec_opts())
      assert completed.disposition == :accepted
      assert completed.plan_task_id == "alpha"

      assert {:ok, status} = Cobbler.plan_execution_status(goal.id)
      assert status.accepted == ["alpha"]
      assert status.completed? == false

      # One admission decision funds exactly one task dispatch.
      assert {:error, {:admission_reused, _detail}} =
               Cobbler.advance_plan_execution(
                 goal.id,
                 exec_opts(admission_event_id: first_admission.id)
               )

      second_admission = admit!(goal)
      second = advance!(goal, admission_event_id: second_admission.id)
      assert second.disposition == :dispatched
      assert second.plan_task_id == "beta"
      assert run_count(goal.id) == 2

      complete_run!(goal, second.run_id)

      assert {:ok, beta_done} =
               Cobbler.complete_plan_task_run(goal.id, second.run_id, exec_opts())

      assert beta_done.disposition == :accepted

      third_admission = admit!(goal)
      done = advance!(goal, admission_event_id: third_admission.id)
      assert done.disposition == :completed
      assert done.commit == PlanFixtures.base_revision()

      assert {:ok, final} = Cobbler.plan_execution_status(goal.id)
      assert final.completed? == true
      assert final.accepted == ["alpha", "beta"]
      assert final.total_attempts == 2
    end

    test "independent nodes still serialize: one active plan task per goal", %{goal: goal} do
      rev = propose_and_approve!(goal, independent_plan())
      admission = admit!(goal)
      assert :recorded = elem(request!(goal, rev, admission), 0)

      first = advance!(goal, admission_event_id: admission.id)
      assert first.disposition == :dispatched
      assert first.plan_task_id == "north"

      assert %{disposition: :awaiting_task} = advance!(goal, admission_event_id: admission.id)
      assert run_count(goal.id) == 1

      complete_run!(goal, first.run_id)
      assert {:ok, _} = Cobbler.complete_plan_task_run(goal.id, first.run_id, exec_opts())

      other_admission = admit!(goal)
      second = advance!(goal, admission_event_id: other_admission.id)
      assert second.plan_task_id == "south"
      assert run_count(goal.id) == 2
    end
  end

  describe "gate acceptance" do
    test "a successful run without passing gates cannot unlock dependents", %{goal: goal} do
      rev = propose_and_approve!(goal)
      admission = admit!(goal)
      assert :recorded = elem(request!(goal, rev, admission), 0)

      first = advance!(goal, admission_event_id: admission.id)
      complete_run!(goal, first.run_id)

      failing = exec_opts(gate_runner_opts: gate_opts(exit_status: 1))

      assert {:ok, failed} = Cobbler.complete_plan_task_run(goal.id, first.run_id, failing)
      assert failed.disposition == :gate_failed
      assert failed.retry_state == "retry"

      assert {:ok, status} = Cobbler.plan_execution_status(goal.id)
      assert status.accepted == []
      assert status.completed? == false

      # The failed attempt retries with a fresh admission, but the
      # dependent stays blocked: only the failed task re-dispatches.
      retry_admission = admit!(goal)
      retried = advance!(goal, admission_event_id: retry_admission.id)
      assert retried.disposition == :dispatched
      assert retried.plan_task_id == "alpha"
      assert retried.attempt == 2
      assert run_count(goal.id) == 2
    end

    test "a failing global gate blocks goal completion", %{goal: goal} do
      rev = propose_and_approve!(goal)
      admission = admit!(goal)
      assert :recorded = elem(request!(goal, rev, admission), 0)

      first = advance!(goal, admission_event_id: admission.id)
      complete_run!(goal, first.run_id)
      assert {:ok, _} = Cobbler.complete_plan_task_run(goal.id, first.run_id, exec_opts())

      second_admission = admit!(goal)
      second = advance!(goal, admission_event_id: second_admission.id)
      complete_run!(goal, second.run_id)
      assert {:ok, _} = Cobbler.complete_plan_task_run(goal.id, second.run_id, exec_opts())

      third_admission = admit!(goal)

      assert {:error, {:global_gate_failed, _detail}} =
               Cobbler.advance_plan_execution(
                 goal.id,
                 exec_opts(
                   admission_event_id: third_admission.id,
                   gate_runner_opts: gate_opts(exit_status: 1)
                 )
               )

      assert {:ok, status} = Cobbler.plan_execution_status(goal.id)
      assert status.completed? == false
    end

    test "completing a run that is not terminal is refused", %{goal: goal} do
      rev = propose_and_approve!(goal)
      admission = admit!(goal)
      assert :recorded = elem(request!(goal, rev, admission), 0)

      first = advance!(goal, admission_event_id: admission.id)

      assert {:error, {:run_not_terminal, _run_id}} =
               Cobbler.complete_plan_task_run(goal.id, first.run_id, exec_opts())
    end

    test "a gate-runner failure records a bounded outcome and leaves dependents blocked", %{
      goal: goal
    } do
      rev = propose_and_approve!(goal)
      admission = admit!(goal)
      assert :recorded = elem(request!(goal, rev, admission), 0)

      first = advance!(goal, admission_event_id: admission.id)
      complete_run!(goal, first.run_id)

      broken =
        exec_opts(
          gate_runner_opts:
            [runner: fn _a, _w, _t -> {:error, :boom} end] ++ Keyword.delete(gate_opts(), :runner)
        )

      assert {:ok, %{disposition: :gate_failed, retry_state: "retry", reason: ":boom"}} =
               Cobbler.complete_plan_task_run(goal.id, first.run_id, broken)

      assert {:ok, status} = Cobbler.plan_execution_status(goal.id)
      assert status.accepted == []

      assert status.active_task == nil
      assert status.total_attempts == 1
      retry_admission = admit!(goal)

      assert %{disposition: :dispatched, plan_task_id: "alpha", attempt: 2} =
               advance!(goal, admission_event_id: retry_admission.id)
    end
  end

  describe "bounded retries" do
    test "a task that exhausts its attempts escalates and blocks", %{goal: goal} do
      plan =
        chain_plan(%{
          "tasks" => [
            PlanFixtures.task("solo", "Only task", [], %{
              "execution" => %{"max_attempts" => 1, "max_duration_seconds" => 600}
            })
          ],
          "budget" => %{"max_total_attempts" => 6, "max_total_duration_seconds" => 7_200}
        })

      rev = propose_and_approve!(goal, plan)
      admission = admit!(goal)
      assert :recorded = elem(request!(goal, rev, admission), 0)

      first = advance!(goal, admission_event_id: admission.id)
      assert first.plan_task_id == "solo"
      complete_run!(goal, first.run_id)

      failing = exec_opts(gate_runner_opts: gate_opts(exit_status: 1))

      assert {:ok, %{disposition: :gate_failed, retry_state: "escalate"}} =
               Cobbler.complete_plan_task_run(goal.id, first.run_id, failing)

      assert %{disposition: :blocked} = advance!(goal, admission_event_id: admission.id)
      assert run_count(goal.id) == 1
    end

    test "total budget exhaustion needs the operator", %{goal: goal} do
      # One task with two attempts and a total budget of two: the first
      # failure retries, the second spends the budget exactly.
      plan =
        chain_plan(%{
          "tasks" => [PlanFixtures.task("solo", "Only task", [])],
          "budget" => %{"max_total_attempts" => 2, "max_total_duration_seconds" => 7_200}
        })

      rev = propose_and_approve!(goal, plan)
      admission = admit!(goal)
      assert :recorded = elem(request!(goal, rev, admission), 0)

      first = advance!(goal, admission_event_id: admission.id)
      complete_run!(goal, first.run_id)

      failing = exec_opts(gate_runner_opts: gate_opts(exit_status: 1))

      assert {:ok, %{retry_state: "retry"}} =
               Cobbler.complete_plan_task_run(goal.id, first.run_id, failing)

      retry_admission = admit!(goal)
      second = advance!(goal, admission_event_id: retry_admission.id)
      assert second.attempt == 2
      complete_run!(goal, second.run_id)

      assert {:ok, %{retry_state: "needs_user"}} =
               Cobbler.complete_plan_task_run(goal.id, second.run_id, failing)

      spent_admission = admit!(goal)
      assert %{disposition: :blocked} = advance!(goal, admission_event_id: spent_admission.id)
      assert run_count(goal.id) == 2
    end

    test "a retry dispatches a new attempt and counters only grow", %{goal: goal} do
      plan =
        chain_plan(%{
          "tasks" => [PlanFixtures.task("solo", "Only task", [])],
          "budget" => %{"max_total_attempts" => 6, "max_total_duration_seconds" => 7_200}
        })

      rev = propose_and_approve!(goal, plan)
      admission = admit!(goal)
      assert :recorded = elem(request!(goal, rev, admission), 0)

      first = advance!(goal, admission_event_id: admission.id)
      assert first.attempt == 1
      complete_run!(goal, first.run_id)

      failing = exec_opts(gate_runner_opts: gate_opts(exit_status: 1))

      assert {:ok, %{retry_state: "retry"}} =
               Cobbler.complete_plan_task_run(goal.id, first.run_id, failing)

      assert {:ok, before} = Cobbler.plan_execution_status(goal.id)
      assert before.total_attempts == 1

      retry_admission = admit!(goal)
      second = advance!(goal, admission_event_id: retry_admission.id)
      assert second.attempt == 2
      assert second.run_id != first.run_id
      assert run_count(goal.id) == 2

      complete_run!(goal, second.run_id)
      assert {:ok, _} = Cobbler.complete_plan_task_run(goal.id, second.run_id, exec_opts())

      assert {:ok, after_retry} = Cobbler.plan_execution_status(goal.id)
      assert after_retry.attempts == %{"solo" => 2}
      assert after_retry.total_attempts == 2
      assert after_retry.total_gate_duration_ms > 0
    end
  end

  describe "restart and duplicate continuation" do
    test "restart resumes after task one without re-executing it", %{goal: goal} do
      rev = propose_and_approve!(goal)
      admission = admit!(goal)
      assert :recorded = elem(request!(goal, rev, admission), 0)

      first = advance!(goal, admission_event_id: admission.id)
      complete_run!(goal, first.run_id)
      assert {:ok, _} = Cobbler.complete_plan_task_run(goal.id, first.run_id, exec_opts())

      # Simulated restart: the executor holds no process state, so a
      # fresh resume call rebuilds everything from events. Each new
      # dispatch consumes a fresh admission (quota re-evaluation).
      fresh_admission = admit!(goal)

      assert {:ok, continued} =
               Cobbler.resume_plan_execution(
                 goal.id,
                 exec_opts(admission_event_id: fresh_admission.id)
               )

      assert continued.disposition == :dispatched
      assert continued.plan_task_id == "beta"
      assert run_count(goal.id) == 2

      # Duplicate wakes replay idempotently: no second continuation.
      assert {:ok, duplicate} =
               Cobbler.resume_plan_execution(
                 goal.id,
                 exec_opts(admission_event_id: fresh_admission.id)
               )

      assert duplicate.disposition == :awaiting_task
      assert run_count(goal.id) == 2

      assert {:ok, status} = Cobbler.plan_execution_status(goal.id)
      assert status.accepted == ["alpha"]
      assert status.total_attempts == 2
    end

    test "duplicate execution requests replay without a second dispatch", %{goal: goal} do
      rev = propose_and_approve!(goal)
      admission = admit!(goal)
      assert :recorded = elem(request!(goal, rev, admission), 0)

      assert {:ok, %{outcome: :replayed}} =
               Cobbler.request_plan_execution(
                 goal.id,
                 %{
                   revision_number: rev.revision_number,
                   digest: rev.digest,
                   admission_event_id: admission.id
                 },
                 exec_opts()
               )

      first = advance!(goal, admission_event_id: admission.id)
      assert first.disposition == :dispatched
      assert run_count(goal.id) == 1
    end

    test "concurrent kickoff cannot dispatch twice", %{goal: goal} do
      rev = propose_and_approve!(goal)
      admission = admit!(goal)
      assert :recorded = elem(request!(goal, rev, admission), 0)

      caller_opts = exec_opts(admission_event_id: admission.id)

      tasks =
        for _ <- 1..2 do
          Task.async(fn -> Cobbler.advance_plan_execution(goal.id, caller_opts) end)
        end

      results = Task.await_many(tasks, 30_000)

      # At most one run exists no matter how the racers interleaved: the
      # stores converge identical intents (deterministic command, run,
      # and dispatch ids) instead of duplicating them. A loser either
      # awaited or refused the already-consumed admission; a follow-up
      # advance converges it cleanly.
      assert run_count(goal.id) == 1

      for {:error, _reason} <- results do
        assert {:ok, _} = Cobbler.advance_plan_execution(goal.id, caller_opts)
      end

      assert run_count(goal.id) == 1

      assert {:ok, status} = Cobbler.plan_execution_status(goal.id)
      assert status.total_attempts == 1
    end
  end

  describe "supersession at the safe boundary" do
    test "a newer approval stops dispatch while the active attempt still records", %{goal: goal} do
      rev = propose_and_approve!(goal)
      admission = admit!(goal)
      assert :recorded = elem(request!(goal, rev, admission), 0)

      first = advance!(goal, admission_event_id: admission.id)
      assert first.plan_task_id == "alpha"

      edited =
        chain_plan(%{
          "tasks" => [
            PlanFixtures.task("alpha", "Do the first thing", []),
            PlanFixtures.task("beta", "Do the second thing, revised", ["alpha"])
          ]
        })

      plan_opts = [now: now(), publish_fun: fn _event -> :ok end]

      assert {:ok, %{revision: revision2}} =
               Plans.propose(
                 goal.id,
                 PlanFixtures.propose_attrs(
                   proposal_id: "proposal-2",
                   parent_revision_number: 1,
                   plan: edited
                 ),
                 plan_opts
               )

      assert {:ok, _} =
               Plans.approve(
                 goal.id,
                 PlanFixtures.approve_attrs(revision2.revision_number, revision2.digest,
                   decision_id: "decision-2"
                 ),
                 plan_opts
               )

      # The in-flight attempt still reaches its safe boundary: gates run
      # and the result is recorded against the revision it ran under.
      complete_run!(goal, first.run_id)

      assert {:ok, recorded} =
               Cobbler.complete_plan_task_run(goal.id, first.run_id, exec_opts())

      assert recorded.disposition == :accepted

      # But no further dispatch flows from the old revision.
      fresh_admission = admit!(goal)

      assert {:error, {:authority_mismatch, _detail}} =
               Cobbler.advance_plan_execution(
                 goal.id,
                 exec_opts(admission_event_id: fresh_admission.id)
               )

      assert run_count(goal.id) == 1
    end
  end

  describe "unplanned goals are untouched" do
    test "ordinary goals keep their behavior", %{goal: goal} do
      assert {:ok, %{planned?: false, completed?: false}} =
               Cobbler.plan_execution_status(goal.id)

      assert PlanExecutor.event_types() |> length() == 5
    end
  end
end
