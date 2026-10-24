defmodule Shoestring.Cobbler.PlanClaimReleaseTest do
  @moduledoc """
  The sequential executor's task claim is released once the chain stops for a
  human decision or the execution is cancelled. Before this fix only the next
  attempt's dispatch (or completion) released it, so a task whose last attempt
  failed kept the global claim, and every other goal's planning and admission
  was refused as "currently occupied by active execution". Hermetic: Fake-grade
  admission, an injected gate runner, no provider and no OS gate process.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Cobbler
  alias Shoestring.Cobbler.{Commands, ExecutionControl, PlanCancellation, PlanExecutor}
  alias Shoestring.Test.{CobblerHelpers, PlanFixtures}

  import Shoestring.Test.PlanExecutorHelpers,
    only: [
      admit!: 1,
      chain_plan: 1,
      complete_run!: 2,
      exec_opts: 0,
      exec_opts: 1,
      gate_opts: 0,
      gate_opts: 1,
      propose_and_approve!: 1,
      propose_and_approve!: 2
    ]

  setup do
    %{goal: CobblerHelpers.create_goal!()}
  end

  defp solo_plan(max_attempts) do
    chain_plan(%{
      "tasks" => [
        PlanFixtures.task("solo", "Only task", [], %{
          "execution" => %{"max_attempts" => max_attempts, "max_duration_seconds" => 600}
        })
      ],
      "budget" => %{"max_total_attempts" => 6, "max_total_duration_seconds" => 7_200}
    })
  end

  # Approves `plan`, dispatches its first task and completes the run, so the
  # goal holds the claim of that attempt.
  defp first_attempt!(goal, plan) do
    rev = if plan, do: propose_and_approve!(goal, plan), else: propose_and_approve!(goal)
    admission = admit!(goal)

    assert {:ok, %{outcome: :recorded}} =
             Cobbler.request_plan_execution(
               goal.id,
               %{
                 revision_number: rev.revision_number,
                 digest: rev.digest,
                 admission_event_id: admission.id
               },
               exec_opts()
             )

    assert {:ok, first} =
             Cobbler.advance_plan_execution(goal.id, exec_opts(admission_event_id: admission.id))

    complete_run!(goal, first.run_id)
    assert %{goal_id: goal_id} = Commands.active_claim()
    assert goal_id == goal.id
    first
  end

  test "a task whose last attempt fails releases its claim", %{goal: goal} do
    first = first_attempt!(goal, solo_plan(1))

    assert {:ok, %{disposition: :gate_failed, retry_state: "escalate"}} =
             Cobbler.complete_plan_task_run(
               goal.id,
               first.run_id,
               exec_opts(gate_runner_opts: gate_opts(exit_status: 1))
             )

    assert Commands.active_claim() == nil
  end

  test "a check that cannot run stops for the user and releases the claim", %{goal: goal} do
    first = first_attempt!(goal, solo_plan(3))

    unavailable = fn _argv, _worktree, _timeout ->
      {:error, {:gate_unavailable, %{reason: :no_sandbox_mechanism}}}
    end

    assert {:ok, %{retry_state: "needs_user"}} =
             Cobbler.complete_plan_task_run(
               goal.id,
               first.run_id,
               exec_opts(gate_runner_opts: Keyword.put(gate_opts(), :runner, unavailable))
             )

    assert Commands.active_claim() == nil
  end

  test "a retryable failure keeps the claim for the next attempt", %{goal: goal} do
    first = first_attempt!(goal, solo_plan(3))

    assert {:ok, %{retry_state: "retry"}} =
             Cobbler.complete_plan_task_run(
               goal.id,
               first.run_id,
               exec_opts(gate_runner_opts: gate_opts(exit_status: 1))
             )

    assert Commands.active_claim().goal_id == goal.id

    # The next attempt still takes over the claim as before.
    assert {:ok, %{disposition: :dispatched, attempt: 2}} =
             Cobbler.advance_plan_execution(
               goal.id,
               exec_opts(admission_event_id: admit!(goal).id)
             )

    assert Commands.active_claim().command_id == "plan-solo-2"
  end

  test "a failed global check releases the claim", %{goal: goal} do
    first = first_attempt!(goal, nil)
    assert {:ok, _} = Cobbler.complete_plan_task_run(goal.id, first.run_id, exec_opts())

    assert {:ok, second} =
             Cobbler.advance_plan_execution(
               goal.id,
               exec_opts(admission_event_id: admit!(goal).id)
             )

    complete_run!(goal, second.run_id)
    assert {:ok, _} = Cobbler.complete_plan_task_run(goal.id, second.run_id, exec_opts())
    assert Commands.active_claim().goal_id == goal.id

    assert {:error, {:global_gate_failed, _}} =
             Cobbler.advance_plan_execution(
               goal.id,
               exec_opts(
                 admission_event_id: admit!(goal).id,
                 gate_runner_opts: gate_opts(exit_status: 1)
               )
             )

    assert Commands.active_claim() == nil
  end

  test "cancelling the execution releases the claim it still holds", %{goal: goal} do
    # A retryable failure: the claim waits for the next attempt, which the
    # cancellation then fences forever.
    first = first_attempt!(goal, solo_plan(3))

    assert {:ok, %{retry_state: "retry"}} =
             Cobbler.complete_plan_task_run(
               goal.id,
               first.run_id,
               exec_opts(gate_runner_opts: gate_opts(exit_status: 1))
             )

    {:ok, %{execution: execution}} = PlanExecutor.status(goal.id)

    assert {:ok, %{cancellation_id: id}} =
             ExecutionControl.cancel(goal.id, %{
               execution_id: execution.execution_id,
               reason: "Stop this work.",
               command_id: Ecto.UUID.generate(),
               requested_by: "human:operator"
             })

    assert {:ok, %{outcome: :completed}} =
             PlanCancellation.perform(goal.id, id, exec_opts(elf_lookup: fn _ -> nil end))

    assert Commands.active_claim() == nil
  end
end
