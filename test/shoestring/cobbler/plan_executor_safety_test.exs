defmodule Shoestring.Cobbler.PlanExecutorSafetyTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.Cobbler
  alias Shoestring.Test.{CobblerHelpers, PlanExecutorHelpers}
  alias Shoestring.Trajectory

  import PlanExecutorHelpers

  for terminal <- ["run.failed", "run.interrupted", "run.cancelled"] do
    test "#{terminal} cannot be accepted by passing gates" do
      goal = CobblerHelpers.create_goal!()
      rev = propose_and_approve!(goal)
      admission = admit!(goal)

      assert {:ok, _} =
               Cobbler.request_plan_execution(
                 goal.id,
                 %{
                   revision_number: rev.revision_number,
                   digest: rev.digest,
                   admission_event_id: admission.id
                 },
                 exec_opts()
               )

      assert {:ok, dispatched} =
               Cobbler.advance_plan_execution(
                 goal.id,
                 exec_opts(admission_event_id: admission.id)
               )

      payload =
        if unquote(terminal) == "run.failed",
          do: %{
            "run_id" => dispatched.run_id,
            "error_category" => "transport",
            "error_code" => "fixture_failure"
          },
          else: %{"run_id" => dispatched.run_id}

      appended =
        Trajectory.append(
          goal.id,
          %{
            "type" => unquote(terminal),
            "schema_version" => 1,
            "actor" => "test",
            "occurred_at" => now(),
            "payload" => payload
          },
          trusted: [run_id: dispatched.run_id]
        )

      assert {:ok, _} = appended

      gates = fn _, _, _ -> flunk("gates must not accept an unsuccessful run") end
      opts = exec_opts(gate_runner_opts: Keyword.put(gate_opts(), :runner, gates))

      case unquote(terminal) do
        "run.failed" ->
          assert {:ok, %{disposition: :gate_failed, retry_state: "retry"}} =
                   Cobbler.complete_plan_task_run(goal.id, dispatched.run_id, opts)

          next_admission = admit!(goal)

          assert {:ok, %{plan_task_id: "alpha", attempt: 2}} =
                   Cobbler.advance_plan_execution(
                     goal.id,
                     exec_opts(admission_event_id: next_admission.id)
                   )

        terminal ->
          assert {:error, {:run_not_completed, %{type: ^terminal}}} =
                   Cobbler.complete_plan_task_run(goal.id, dispatched.run_id, opts)

          assert {:ok, %{disposition: :awaiting_task, active_run_id: run_id}} =
                   Cobbler.resume_plan_execution(goal.id, opts)

          assert run_id == dispatched.run_id
      end

      assert {:ok, %{accepted: [], completed?: false}} = Cobbler.plan_execution_status(goal.id)
    end
  end

  test "supersession refuses an unstarted worker while preserving its recorded intent" do
    goal = CobblerHelpers.create_goal!()
    rev = propose_and_approve!(goal)
    admission = admit!(goal)

    assert {:ok, _} =
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

    run = Repo.get!(Shoestring.Harness.RunRecord, first.run_id)
    assert run.extensions["shoestring.plan:binding"]["plan_digest"] == rev.digest
    assert run.prompt =~ "acceptance_criteria"
    assert run.prompt =~ "checkpoint"

    plan_opts = [now: now(), publish_fun: fn _ -> :ok end]

    assert {:ok, %{revision: newer}} =
             Shoestring.Cobbler.Plans.propose(
               goal.id,
               Shoestring.Test.PlanFixtures.propose_attrs(
                 plan: chain_plan(),
                 proposal_id: "amend-2",
                 parent_revision_number: 1
               ),
               plan_opts
             )

    assert {:ok, _} =
             Shoestring.Cobbler.Plans.approve(
               goal.id,
               Shoestring.Test.PlanFixtures.approve_attrs(newer.revision_number, newer.digest,
                 decision_id: "approve-2"
               ),
               plan_opts
             )

    assert {:error, :plan_authority_changed} =
             Shoestring.Harness.Dispatches.prepare_for_effect(run.dispatch_id)

    assert Repo.get!(Shoestring.Harness.DispatchRecord, run.dispatch_id).status == "requested"
    assert Repo.get!(Shoestring.Harness.RunRecord, run.id).status == "requested"

    assert {:error, :plan_authority_changed} =
             Shoestring.Harness.Dispatches.enqueue_for_run(run,
               repo: Repo
             )
             |> then(fn
               {:ok, _, _} -> Shoestring.Harness.Dispatches.prepare_for_effect(run.dispatch_id)
               error -> error
             end)
  end

  test "quota refusal keeps the same task and attempt awaiting its wake lifecycle" do
    goal = CobblerHelpers.create_goal!()
    rev = propose_and_approve!(goal)
    admission = admit!(goal)

    assert {:ok, _} =
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

    appended =
      Trajectory.append(
        goal.id,
        %{
          "type" => "run.failed",
          "schema_version" => 1,
          "actor" => "test",
          "occurred_at" => now(),
          "payload" => %{
            "run_id" => first.run_id,
            "error_category" => "quota_refused",
            "error_code" => "rate_limit_exceeded"
          }
        },
        trusted: [run_id: first.run_id]
      )

    assert {:ok, _} = appended

    assert {:error, {:run_requires_continuation, run_id}} =
             Cobbler.complete_plan_task_run(goal.id, first.run_id, exec_opts())

    assert run_id == first.run_id

    assert {:ok, %{disposition: :awaiting_task, active_run_id: ^run_id, active_attempt: 1}} =
             Cobbler.resume_plan_execution(goal.id, exec_opts())

    assert {:ok, %{accepted: [], total_attempts: 1}} = Cobbler.plan_execution_status(goal.id)
    assert run_count(goal.id) == 1
  end
end
