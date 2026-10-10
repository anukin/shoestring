defmodule Shoestring.Cobbler.PlannerAmendmentTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.Cobbler
  alias Shoestring.Cobbler.{Commands, PlanContract, Planner, PlannerRequestRecord, Plans}
  alias Shoestring.Test.{CobblerHelpers, PlanFixtures, PlannerFixtures}
  alias Shoestring.Trajectory.TrajectoryEvent
  import Shoestring.Test.PlanExecutorHelpers

  setup do
    %{supervisor: start_supervised!(Task.Supervisor), goal: CobblerHelpers.create_goal!()}
  end

  defp options(ctx, responses \\ nil),
    do: [
      now: now(),
      task_supervisor: ctx.supervisor,
      snapshot: PlannerFixtures.snapshot(now()),
      config: PlannerFixtures.config(responses || [{:ok, Jason.encode!(chain_plan()), 12}])
    ]

  defp attrs(revision, extra \\ %{}),
    do:
      Map.merge(
        %{
          revision_number: revision.revision_number,
          digest: revision.digest,
          request_key: "amendment-1",
          requested_by: "human:operator",
          reason: "Revise unfinished work using recorded gate evidence."
        },
        extra
      )

  defp approve!(goal, revision) do
    assert {:ok, _} =
             Plans.approve(
               goal.id,
               PlanFixtures.approve_attrs(revision.revision_number, revision.digest,
                 decision_id: "approve-#{revision.revision_number}"
               ),
               exec_opts()
             )
  end

  defp request_execution(goal, revision) do
    admission = admit!(goal)

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

  defp accept!(goal, run) do
    complete_run!(goal, run.run_id)

    assert {:ok, %{disposition: :accepted}} =
             Cobbler.complete_plan_task_run(goal.id, run.run_id, exec_opts())
  end

  defp revised(plan, id \\ "beta") do
    plan
    |> Map.delete("planner")
    |> Map.update!("tasks", fn tasks ->
      Enum.map(tasks, fn task ->
        if task["id"] == id,
          do:
            Map.put(task, "outcome", "A revised unfinished outcome with deterministic evidence."),
          else: task
      end)
    end)
  end

  defp adopt!(goal, row, opts) do
    assert {:ok, %{revision: revision}} =
             Planner.adopt(
               goal.id,
               row.request_key,
               %{digest: row.result_digest, authored_by: "human:operator"},
               opts
             )

    revision
  end

  test "initial generation and amendment share charges and preserve accepted execution across approval",
       ctx do
    initial = chain_plan()

    opts =
      options(ctx, [{:ok, Jason.encode!(initial), 12}, {:ok, Jason.encode!(revised(initial)), 15}])

    assert {:ok, _} =
             Planner.request(
               ctx.goal.id,
               %{
                 request_key: "initial-1",
                 requested_by: "human:operator",
                 goal_contract: initial["goal"]
               },
               opts
             )

    assert {:ok, %{request: first}} = Planner.generate(ctx.goal.id, "initial-1", opts)
    revision = adopt!(ctx.goal, first, opts)
    approve!(ctx.goal, revision)
    assert {:ok, _} = request_execution(ctx.goal, revision)
    alpha = dispatch!(ctx.goal)
    accept!(ctx.goal, alpha)
    beta = dispatch!(ctx.goal)
    complete_run!(ctx.goal, beta.run_id)

    assert {:ok, %{retry_state: "retry"}} =
             Cobbler.complete_plan_task_run(
               ctx.goal.id,
               beta.run_id,
               exec_opts(gate_runner_opts: gate_opts(exit_status: 1))
             )

    accepted =
      Repo.one!(
        from e in TrajectoryEvent,
          where: e.goal_id == ^ctx.goal.id and e.type == "cobbler.plan.task.accepted"
      )

    assert {:ok, %{request: pending}} =
             Planner.request_amendment(ctx.goal.id, attrs(revision), opts)

    assert pending.id == first.id
    assert pending.attempts == 1
    assert pending.charged_output_tokens == 4096
    assert pending.attempt_history == first.attempt_history
    assert pending.projection["amendment"]["accepted_task_ids"] == ["alpha"]

    assert Enum.any?(
             pending.projection["source_context_refs"],
             &String.ends_with?(&1, ":cobbler.plan.task.gate_failed")
           )

    assert {:ok, %{request: candidate}} =
             Planner.generate_amendment(ctx.goal.id, "amendment-1", opts)

    assert candidate.state == "ready"
    assert candidate.attempts == 2
    assert candidate.charged_output_tokens == 8192
    assert hd(candidate.attempt_history["items"]) == hd(first.attempt_history["items"])
    assert Commands.active_claim() == nil
    assert {:ok, %{consistent?: true}} = Planner.rebuild(ctx.goal.id)

    assert {:error, :stale_planner_digest} =
             Planner.adopt(
               ctx.goal.id,
               "amendment-1",
               %{digest: first.result_digest, authored_by: "human:operator"},
               opts
             )

    amended = adopt!(ctx.goal, candidate, opts)
    assert amended.parent_revision_number == 1
    assert amended.status == "proposed"
    assert Plans.authority(ctx.goal.id).revision_number == 1
    assert {:error, {:authority_mismatch, _}} = request_execution(ctx.goal, amended)
    approve!(ctx.goal, amended)
    assert {:ok, _} = request_execution(ctx.goal, amended)

    assert {:ok, %{accepted: ["alpha"], total_attempts: 2}} =
             Cobbler.plan_execution_status(ctx.goal.id)

    retry = dispatch!(ctx.goal)
    assert retry.plan_task_id == "beta" and retry.attempt == 2
    accept!(ctx.goal, retry)

    assert {:ok, %{disposition: :completed}} =
             Cobbler.advance_plan_execution(ctx.goal.id, exec_opts())

    assert Repo.get!(TrajectoryEvent, accepted.id) == accepted
    assert {:ok, %{consistent?: true}} = Plans.rebuild(ctx.goal.id)
    assert {:ok, %{consistent?: true}} = Planner.rebuild(ctx.goal.id)

    assert {:ok, %{outcome: :replayed}} =
             Planner.request_amendment(ctx.goal.id, attrs(revision), opts)

    assert {:ok, %{outcome: :replayed}} =
             Planner.generate_amendment(ctx.goal.id, "amendment-1", opts)

    assert_received {:planner_input, %{"attempt" => 1}}

    assert_received {:planner_input,
                     %{
                       "attempt" => 2,
                       "projection" => %{"amendment" => %{"accepted_task_ids" => ["alpha"]}}
                     }}

    refute_received {:planner_input, _}
    assert run_count(ctx.goal.id) == 3
  end

  test "manual plans allow one amendment and one explicit repair within two total calls", ctx do
    revision = propose_and_approve!(ctx.goal)
    assert {:ok, _} = request_execution(ctx.goal, revision)
    alpha = dispatch!(ctx.goal)
    accept!(ctx.goal, alpha)

    opts =
      options(ctx, [
        {:ok, Jason.encode!(revised(chain_plan(), "alpha")), 9},
        {:ok, Jason.encode!(revised(chain_plan())), 10}
      ])

    assert {:ok, %{request: %{attempts: 0}}} =
             Planner.request_amendment(ctx.goal.id, attrs(revision), opts)

    assert {:ok, %{request: invalid}} =
             Planner.generate_amendment(ctx.goal.id, "amendment-1", opts)

    assert invalid.state == "unsafe_proposal"
    assert hd(invalid.errors["items"])["code"] == "amendment_preservation_failed"
    assert {:ok, %{request: repaired}} = Planner.repair(ctx.goal.id, "amendment-1", opts)
    assert repaired.state == "ready" and repaired.attempts == 2
    assert repaired.charged_output_tokens == 8192

    assert_received {:planner_input,
                     %{
                       "attempt" => 2,
                       "validation_errors" => [%{"code" => "amendment_preservation_failed"}]
                     }}

    assert {:error, :planner_repair_unavailable} =
             Planner.repair(ctx.goal.id, "amendment-1", opts)

    assert {:error, :planner_amendment_already_requested} =
             Planner.request_amendment(
               ctx.goal.id,
               attrs(revision, %{request_key: "new-budget"}),
               opts
             )

    assert {:ok, %{consistent?: true}} = Planner.rebuild(ctx.goal.id)
  end

  test "two initial calls leave no amendment allowance and config changes cannot replenish it",
       ctx do
    opts = options(ctx, [{:ok, "invalid", 1}, {:ok, Jason.encode!(chain_plan()), 10}])

    assert {:ok, _} =
             Planner.request(
               ctx.goal.id,
               %{
                 request_key: "initial",
                 requested_by: "human:operator",
                 goal_contract: chain_plan()["goal"]
               },
               opts
             )

    assert {:ok, _} = Planner.generate(ctx.goal.id, "initial", opts)
    assert {:ok, %{request: row}} = Planner.repair(ctx.goal.id, "initial", opts)
    revision = adopt!(ctx.goal, row, opts)
    approve!(ctx.goal, revision)

    assert {:error, :planner_budget_exhausted} =
             Planner.request_amendment(ctx.goal.id, attrs(revision), opts)

    changed = Keyword.update!(opts, :config, &Keyword.put(&1, :max_output_tokens, 8192))

    assert {:error, :planner_configuration_changed} =
             Planner.request_amendment(ctx.goal.id, attrs(revision), changed)

    assert Planner.get(ctx.goal.id).charged_output_tokens == 8192
    assert Planner.get(ctx.goal.id).request_key == "initial"
  end

  test "active work cannot be released or replaced to obtain planning admission", ctx do
    revision = propose_and_approve!(ctx.goal)
    opts = options(ctx)
    assert {:ok, _} = Planner.request_amendment(ctx.goal.id, attrs(revision), opts)
    assert {:ok, _} = request_execution(ctx.goal, revision)
    alpha = dispatch!(ctx.goal)
    claim = Commands.active_claim()

    assert {:error, :active_plan_execution} =
             Planner.generate_amendment(ctx.goal.id, "amendment-1", opts)

    assert Commands.active_claim() == claim
    assert Planner.get(ctx.goal.id).attempts == 0
    assert run_count(ctx.goal.id) == 1
    assert {:ok, %{active_run_id: id}} = Cobbler.plan_execution_status(ctx.goal.id)
    assert id == alpha.run_id
    refute_received {:planner_input, _}
  end

  test "an already activated amendment cannot obtain another inference allowance", ctx do
    first = propose_and_approve!(ctx.goal)
    assert {:ok, _} = request_execution(ctx.goal, first)
    alpha = dispatch!(ctx.goal)
    accept!(ctx.goal, alpha)

    assert {:ok, %{revision: second}} =
             Plans.propose(
               ctx.goal.id,
               PlanFixtures.propose_attrs(
                 plan: chain_plan(),
                 parent_revision_number: 1,
                 proposal_id: "activated-amendment"
               ),
               exec_opts()
             )

    approve!(ctx.goal, second)
    assert {:ok, _} = request_execution(ctx.goal, second)

    assert {:error, :amendment_execution_limit} =
             Planner.request_amendment(ctx.goal.id, attrs(second), options(ctx))

    assert Planner.get(ctx.goal.id) == nil
    refute_received {:planner_input, _}
  end

  test "moved parent refuses generation before charging and refuses adoption after inference",
       ctx do
    revision = propose_and_approve!(ctx.goal)
    opts = options(ctx)
    assert {:ok, _} = Planner.request_amendment(ctx.goal.id, attrs(revision), opts)
    assert {:ok, %{request: row}} = Planner.generate_amendment(ctx.goal.id, "amendment-1", opts)

    assert {:ok, %{revision: newer}} =
             Plans.propose(
               ctx.goal.id,
               PlanFixtures.propose_attrs(
                 plan: chain_plan(),
                 parent_revision_number: 1,
                 proposal_id: "manual-newer"
               ),
               exec_opts()
             )

    approve!(ctx.goal, newer)

    assert {:error, :amendment_parent_changed} =
             Planner.adopt(
               ctx.goal.id,
               "amendment-1",
               %{digest: row.result_digest, authored_by: "human:operator"},
               opts
             )

    assert length(Plans.list_revisions(ctx.goal.id)) == 2
    assert Planner.get(ctx.goal.id).attempts == 1

    other = CobblerHelpers.create_goal!()
    parent = propose_and_approve!(other)
    assert {:ok, _} = Planner.request_amendment(other.id, attrs(parent), opts)

    assert {:ok, %{revision: newer}} =
             Plans.propose(
               other.id,
               PlanFixtures.propose_attrs(
                 plan: chain_plan(),
                 parent_revision_number: 1,
                 proposal_id: "newer"
               ),
               exec_opts()
             )

    approve!(other, newer)

    assert {:error, :amendment_parent_changed} =
             Planner.generate_amendment(other.id, "amendment-1", opts)

    assert Planner.get(other.id).attempts == 0
  end

  test "later accepted evidence is rechecked when adopting a candidate", ctx do
    revision = propose_and_approve!(ctx.goal)
    opts = options(ctx, [{:ok, Jason.encode!(revised(chain_plan(), "alpha")), 9}])
    assert {:ok, _} = Planner.request_amendment(ctx.goal.id, attrs(revision), opts)

    assert {:ok, %{request: candidate}} =
             Planner.generate_amendment(ctx.goal.id, "amendment-1", opts)

    assert {:ok, _} = request_execution(ctx.goal, revision)
    alpha = dispatch!(ctx.goal)
    accept!(ctx.goal, alpha)

    assert {:error, {:accepted_task_contract_changed, "alpha"}} =
             Planner.adopt(
               ctx.goal.id,
               "amendment-1",
               %{digest: candidate.result_digest, authored_by: "human:operator"},
               opts
             )

    assert length(Plans.list_revisions(ctx.goal.id)) == 1
    assert {:ok, %{consistent?: true}} = Planner.rebuild(ctx.goal.id)
  end

  test "models cannot erase prior identities or author scope retirements", ctx do
    revision = propose_and_approve!(ctx.goal)
    erased = Map.put(chain_plan(), "tasks", [hd(chain_plan()["tasks"])])

    retired =
      Map.put(chain_plan(), "retirements", [
        %{"task_id" => "beta", "reason" => "Model retirement"}
      ])

    opts = options(ctx, [{:ok, Jason.encode!(erased), 5}, {:ok, Jason.encode!(retired), 5}])
    assert {:ok, _} = Planner.request_amendment(ctx.goal.id, attrs(revision), opts)

    assert {:ok, %{request: %{state: "unsafe_proposal"}}} =
             Planner.generate_amendment(ctx.goal.id, "amendment-1", opts)

    assert {:ok, %{request: %{state: "unsafe_proposal", attempts: 2}}} =
             Planner.repair(ctx.goal.id, "amendment-1", opts)

    assert Plans.authority(ctx.goal.id).revision_number == 1
    assert run_count(ctx.goal.id) == 0
  end

  test "existing human retirements are preserved in the model schema and proposal", ctx do
    first = propose_and_approve!(ctx.goal)

    plan =
      Map.put(chain_plan(), "retirements", [
        %{"task_id" => "beta", "reason" => "Human scope decision."}
      ])

    assert {:ok, %{revision: parent}} =
             Plans.propose(
               ctx.goal.id,
               PlanFixtures.propose_attrs(
                 plan: plan,
                 parent_revision_number: first.revision_number,
                 proposal_id: "human-retirement"
               ),
               exec_opts()
             )

    approve!(ctx.goal, parent)
    opts = options(ctx, [{:ok, Jason.encode!(plan), 5}])
    assert {:ok, _} = Planner.request_amendment(ctx.goal.id, attrs(parent), opts)

    assert {:ok, %{request: %{state: "ready"}}} =
             Planner.generate_amendment(ctx.goal.id, "amendment-1", opts)

    assert_received {:planner_input,
                     %{
                       "schema" => %{
                         "properties" => %{"retirements" => %{"const" => retirements}}
                       }
                     }}

    assert retirements == plan["retirements"]
  end

  test "oversized context and unreviewed or nonhuman requests persist no allowance", ctx do
    tasks =
      for n <- 1..25,
          do:
            PlanFixtures.task("task-#{n}", "Bounded fixture task", [], %{
              "outcome" => String.duplicate("x", 800)
            })

    plan =
      chain_plan(%{
        "tasks" => tasks,
        "budget" => %{"max_total_attempts" => 50, "max_total_duration_seconds" => 30_000}
      })

    revision = propose_and_approve!(ctx.goal, plan)
    opts = options(ctx)
    assert {:error, _} = Planner.request_amendment(ctx.goal.id, attrs(revision), opts)
    assert Planner.get(ctx.goal.id) == nil
    other = CobblerHelpers.create_goal!()
    revision = propose_and_approve!(other)

    for extra <- [
          %{requested_by: "model:planner"},
          %{digest: String.duplicate("f", 64)},
          %{reason: ""},
          %{revision_number: nil}
        ] do
      assert {:error, _} = Planner.request_amendment(other.id, attrs(revision, extra), opts)
      assert Planner.get(other.id) == nil
    end

    refute_received {:planner_input, _}
  end

  test "canonical replay refuses forged accepted context even when the cache agrees", ctx do
    revision = propose_and_approve!(ctx.goal)
    opts = options(ctx)
    assert {:ok, %{request: row}} = Planner.request_amendment(ctx.goal.id, attrs(revision), opts)
    projection = put_in(row.projection, ["amendment", "accepted_task_ids"], ["beta"])

    digest =
      PlanContract.digest(%{"projection" => projection, "configuration" => row.configuration})

    event =
      Repo.one!(
        from e in TrajectoryEvent,
          where: e.goal_id == ^ctx.goal.id and e.type == "cobbler.planner.amendment.requested"
      )

    payload =
      event.payload
      |> Map.put("projection_json", PlanContract.canonical_json(projection))
      |> Map.put("input_digest", digest)

    Repo.update_all(from(e in TrajectoryEvent, where: e.id == ^event.id), set: [payload: payload])

    Repo.update_all(from(r in PlannerRequestRecord, where: r.id == ^row.id),
      set: [projection: projection, input_digest: digest]
    )

    assert {:error, {:invalid_planner_history, _}} = Planner.rebuild(ctx.goal.id)

    assert {:error, :planner_state_diverged} =
             Planner.generate_amendment(ctx.goal.id, "amendment-1", opts)

    assert Planner.get(ctx.goal.id).charged_output_tokens == 0
    refute_received {:planner_input, _}
  end

  test "an in-flight initial attempt cannot be reset into amendment inference", ctx do
    ref = make_ref()
    opts = options(ctx, [{:await, self(), ref, Jason.encode!(chain_plan()), 10}])

    assert {:ok, _} =
             Planner.request(
               ctx.goal.id,
               %{
                 request_key: "initial",
                 requested_by: "human:operator",
                 goal_contract: chain_plan()["goal"]
               },
               opts
             )

    revision = propose_and_approve!(ctx.goal)

    task =
      Task.Supervisor.async_nolink(ctx.supervisor, fn ->
        Planner.generate(ctx.goal.id, "initial", opts)
      end)

    assert_receive {:planner_waiting, pid, ^ref}

    assert {:error, :planner_attempt_in_flight} =
             Planner.request_amendment(ctx.goal.id, attrs(revision), opts)

    assert Planner.get(ctx.goal.id).request_key == "initial"
    assert Planner.get(ctx.goal.id).charged_output_tokens == 4096
    send(pid, {:continue, ref})
    assert {:ok, %{request: %{state: "ready"}}} = Task.await(task)
  end

  test "lost amendment inference stays owned across supervisor restart without another charge",
       ctx do
    revision = propose_and_approve!(ctx.goal)
    ref = make_ref()
    opts = options(ctx, [{:await, self(), ref, Jason.encode!(chain_plan()), 10}])
    assert {:ok, _} = Planner.request_amendment(ctx.goal.id, attrs(revision), opts)

    task =
      Task.Supervisor.async_nolink(ctx.supervisor, fn ->
        Planner.generate_amendment(ctx.goal.id, "amendment-1", opts)
      end)

    assert_receive {:planner_waiting, pid, ^ref}
    monitor = Process.monitor(pid)
    _ = Task.shutdown(task, :brutal_kill)
    :ok = stop_supervised(Task.Supervisor)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}
    replacement = start_supervised!(Task.Supervisor)
    opts = Keyword.put(opts, :task_supervisor, replacement)

    assert {:ok, %{outcome: :replayed, request: row}} =
             Planner.generate_amendment(ctx.goal.id, "amendment-1", opts)

    assert row.state == "running" and row.attempts == 1 and row.charged_output_tokens == 4096

    assert {:ok, %{outcome: :replayed}} =
             Planner.request_amendment(ctx.goal.id, attrs(revision), opts)

    assert {:ok, %{consistent?: true}} = Planner.rebuild(ctx.goal.id)
    assert Commands.active_claim().goal_id == ctx.goal.id
    assert_received {:planner_input, _}
    refute_received {:planner_input, _}
  end
end
