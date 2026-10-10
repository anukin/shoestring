defmodule Shoestring.Cobbler.PlanDurationTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.{Cobbler, Repo, Trajectory}
  alias Shoestring.Cobbler.Plans
  alias Shoestring.Test.{CobblerHelpers, PlanFixtures}
  import Shoestring.Test.PlanExecutorHelpers

  defp begin!(plan \\ chain_plan()) do
    goal = CobblerHelpers.create_goal!()
    revision = propose_and_approve!(goal, plan)
    request!(goal, revision)
    {goal, dispatch!(goal)}
  end

  defp request!(goal, revision) do
    admission = admit!(goal)

    assert {:ok, _} =
             Cobbler.request_plan_execution(
               goal.id,
               %{
                 revision_number: revision.revision_number,
                 digest: revision.digest,
                 admission_event_id: admission.id
               },
               exec_opts()
             )
  end

  defp dispatch!(goal) do
    admission = admit!(goal)

    assert {:ok, run} =
             Cobbler.advance_plan_execution(goal.id, exec_opts(admission_event_id: admission.id))

    run
  end

  defp event!(goal, run, type, at, extra \\ %{}) do
    assert {:ok, _} =
             Trajectory.append(
               goal.id,
               %{
                 "type" => type,
                 "schema_version" => 1,
                 "actor" => "fixture",
                 "occurred_at" => at,
                 "payload" => Map.put(extra, "run_id", run.run_id)
               },
               trusted: [run_id: run.run_id]
             )
  end

  defp finish!(goal, run, seconds, category \\ nil) do
    event!(goal, run, "run.starting", now())
    at = DateTime.add(now(), seconds)

    if category,
      do:
        event!(goal, run, "run.failed", at, %{
          "error_category" => category,
          "error_code" => "fixture_failure"
        }),
      else: event!(goal, run, "run.completed", at)

    at
  end

  defp gates(ms, extra \\ []) do
    runner = fn _argv, _path, timeout ->
      if observer = extra[:observer], do: send(observer, {:gate_timeout_bound, timeout})

      {:ok,
       %{
         exit_status: extra[:exit_status] || 0,
         output: "Synthetic duration fixture",
         duration_ms: ms
       }}
    end

    Keyword.put(gate_opts(), :runner, runner)
  end

  @tag :duration_regression
  test "provider time exhausts a task even when its retry count permits another attempt" do
    {goal, run} = begin!()
    at = finish!(goal, run, 1201, "transport")

    assert {:ok, %{disposition: :gate_failed, retry_state: "escalate"}} =
             Cobbler.complete_plan_task_run(goal.id, run.run_id, exec_opts(now: at))

    assert {:ok, %{disposition: :blocked}} =
             Cobbler.advance_plan_execution(goal.id, exec_opts(now: at))

    assert run_count(goal.id) == 1
    assert {:ok, status} = Cobbler.plan_execution_status(goal.id, now: at)
    assert status.total_run_duration_ms == 1_201_000
    assert status.total_duration_ms == 1_201_000
  end

  @tag :duration_regression
  test "a paused quota attempt with no duration left cannot continue" do
    {goal, run} = begin!()
    at = finish!(goal, run, 1201, "quota_refused")

    assert {:error, :task_duration_exhausted} =
             Cobbler.resume_plan_execution(goal.id, exec_opts(now: at))

    assert run_count(goal.id) == 1
    assert {:ok, status} = Cobbler.plan_execution_status(goal.id, now: at)
    assert status.needs_user?
    assert status.duration_budget.reason == :task_duration_exhausted
  end

  test "elapsed time alone leaves an active run owned and awaiting completion" do
    {goal, run} = begin!()
    event!(goal, run, "run.starting", now())
    at = DateTime.add(now(), 1201)

    assert {:ok, %{disposition: :awaiting_task, active_run_id: id}} =
             Cobbler.advance_plan_execution(goal.id, exec_opts(now: at))

    assert id == run.run_id
    assert run_count(goal.id) == 1
    assert {:ok, status} = Cobbler.plan_execution_status(goal.id, now: at)
    refute status.needs_user?
    assert status.duration_budget.reason == :task_duration_exhausted

    refute Repo.exists?(
             from e in Shoestring.Trajectory.TrajectoryEvent,
               where: e.goal_id == ^goal.id and e.type in ["run.cancelled", "run.interrupted"]
           )
  end

  @tag :duration_regression
  test "task gates cannot consume more than the remaining task duration" do
    {goal, run} = begin!()
    at = finish!(goal, run, 1199)

    assert {:ok, %{disposition: :gate_failed, retry_state: "escalate"}} =
             Cobbler.complete_plan_task_run(
               goal.id,
               run.run_id,
               exec_opts(now: at, gate_runner_opts: gates(1001, observer: self()))
             )

    assert_receive {:gate_timeout_bound, 1000}
    assert {:ok, status} = Cobbler.plan_execution_status(goal.id, now: at)
    assert status.accepted == []
    assert status.total_gate_duration_ms == 1001
  end

  @tag :duration_regression
  test "approved amendment carries provider duration from the previous execution" do
    {goal, run} = begin!()
    at = finish!(goal, run, 601, "transport")

    assert {:ok, %{retry_state: "retry"}} =
             Cobbler.complete_plan_task_run(goal.id, run.run_id, exec_opts(now: at))

    assert {:ok, %{revision: revision}} =
             Plans.propose(
               goal.id,
               PlanFixtures.propose_attrs(
                 plan: chain_plan(),
                 parent_revision_number: 1,
                 proposal_id: "duration-amendment"
               ),
               exec_opts(now: at)
             )

    assert {:ok, _} =
             Plans.approve(
               goal.id,
               PlanFixtures.approve_attrs(2, revision.digest, decision_id: "approve-duration-2"),
               exec_opts(now: at)
             )

    request!(goal, revision)
    second = dispatch!(goal)
    at = finish!(goal, second, 599)

    assert {:ok, %{disposition: :gate_failed}} =
             Cobbler.complete_plan_task_run(
               goal.id,
               second.run_id,
               exec_opts(now: at, gate_runner_opts: gates(7, observer: self()))
             )

    refute_receive {:gate_timeout_bound, _}
    assert {:ok, status} = Cobbler.plan_execution_status(goal.id, now: at)
    assert status.total_run_duration_ms == 1_200_000
    assert status.total_attempts == 2
    assert status.accepted == []
  end

  @tag :duration_regression
  test "global acceptance spends remaining goal duration and cannot retry after failure" do
    plan =
      chain_plan(%{
        "budget" => %{"max_total_attempts" => 6, "max_total_duration_seconds" => 20},
        "tasks" => [
          PlanFixtures.task("alpha", "First", [], %{
            "execution" => %{"max_attempts" => 2, "max_duration_seconds" => 10}
          }),
          PlanFixtures.task("beta", "Second", ["alpha"], %{
            "execution" => %{"max_attempts" => 2, "max_duration_seconds" => 10}
          })
        ]
      })

    {goal, alpha} = begin!(plan)
    at = finish!(goal, alpha, 6)

    assert {:ok, %{disposition: :accepted}} =
             Cobbler.complete_plan_task_run(
               goal.id,
               alpha.run_id,
               exec_opts(now: at, gate_runner_opts: gates(2000))
             )

    beta = dispatch!(goal)
    at = finish!(goal, beta, 8)

    assert {:ok, %{disposition: :accepted}} =
             Cobbler.complete_plan_task_run(
               goal.id,
               beta.run_id,
               exec_opts(now: at, gate_runner_opts: gates(2000))
             )

    assert {:error, {:global_gate_failed, _}} =
             Cobbler.advance_plan_execution(
               goal.id,
               exec_opts(now: at, gate_runner_opts: gates(3000, observer: self()))
             )

    assert_receive {:gate_timeout_bound, 2000}

    assert {:error, {:global_gate_failed, _}} =
             Cobbler.resume_plan_execution(
               goal.id,
               exec_opts(now: at, gate_runner_opts: gates(1, observer: self()))
             )

    refute_receive {:gate_timeout_bound, _}
    assert {:ok, status} = Cobbler.plan_execution_status(goal.id, now: at)
    assert status.needs_user?
    refute status.completed?
    assert status.total_duration_ms == 21_000
    assert status.total_gate_duration_ms == 7000
  end
end
