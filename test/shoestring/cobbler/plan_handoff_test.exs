defmodule Shoestring.Cobbler.PlanHandoffTest do
  use Shoestring.DataCase, async: false
  import Shoestring.Test.PlanExecutorHelpers
  import Shoestring.Test.PlanHandoffHelpers
  alias Shoestring.{AgentProfiles, Cobbler}
  alias Shoestring.Cobbler.{Commands, Handoffs, PlanRunLineage}
  alias Shoestring.Harness.{RunRecord, Runs}

  setup context do
    fixture(context[:handoff_stop] || :quota)
  end

  @tag :plan_handoff_regression
  test "an explicit saved receiver role continues one approved attempt and unlocks the dependent",
       c do
    command = request!(c)
    assert command.status == "resolved"
    assert run_count(c.goal.id) == 1

    assert {:ok, %{outcome: :dispatched, run: receiver}} =
             Handoffs.perform(c.goal.id, command.command_id, perform_opts())

    assert command.result["receiver_profile"]["model"] == "fixture-reviewer"
    assert command.result["handoff_id"] == command.id
    assert receiver.id == command.id
    assert receiver.workspace_ref == c.run.workspace_ref
    assert receiver.task_id == c.run.task_id
    assert receiver.provider_id == "claude_headless_stream_json"
    assert receiver.extensions["shoestring.agent:binding"] == command.result["receiver_profile"]

    assert receiver.extensions["shoestring.plan:binding"] ==
             c.run.extensions["shoestring.plan:binding"]

    assert receiver.prompt =~ c.agent.instructions
    assert {:ok, chains} = PlanRunLineage.load(Repo, c.goal.id)
    assert chains[c.run.id] == [c.run.id, receiver.id]

    assert {:ok, %{total_attempts: 1, active_run_id: id}} =
             Cobbler.plan_execution_status(c.goal.id)

    assert id == receiver.id

    assert {:ok, %{outcome: :converged, run: replayed}} =
             Handoffs.perform(c.goal.id, command.command_id, perform_opts())

    assert replayed.id == receiver.id
    assert run_count(c.goal.id) == 2
    assert {:ok, %{repaired_count: 0, failures: []}} = Handoffs.reconcile(now: now())
    assert {:ok, _} = Commands.rebuild(c.goal.id)
    complete_run!(c.goal, receiver.id)
    admission = worker_admission(c.goal)

    assert {:ok, %{disposition: :dispatched, plan_task_id: "beta", run_id: beta_id}} =
             Cobbler.resume_plan_execution(c.goal.id, exec_opts(admission_event_id: admission.id))

    assert Repo.get!(RunRecord, beta_id).provider_id == c.run.provider_id

    assert {:ok, %{accepted: ["alpha"], total_attempts: 2}} =
             Cobbler.plan_execution_status(c.goal.id)
  end

  @tag :plan_handoff_regression
  test "an implicit receiver is rejected without queueing or observing", c do
    attributes = update_in(attrs(c), ["payload"], &Map.delete(&1, "receiver_role"))
    command = request!(c, attributes)
    assert command.status == "rejected"
    assert command.result["reason"] == "handoff_receiver_role_mismatch"
    assert Repo.aggregate(Oban.Job, :count, :id) == 1
    assert run_count(c.goal.id) == 1
  end

  test "unknown, default-model and target-mismatched roles are rejected", c do
    for {key, value} <- [
          {"receiver_role", "Unknown"},
          {"receiver_role", "Coordinator"},
          {"to_provider_id", "codex"},
          {"to_adapter_id", "codex_app_server_stdio"}
        ] do
      command = request!(c, put_in(attrs(c), ["payload", key], value))
      assert command.status == "rejected"
      assert command.result["reason"] == "handoff_receiver_role_mismatch"
    end

    assert run_count(c.goal.id) == 1
  end

  test "configuration edits after intent cannot replace the pinned receiver", c do
    command = request!(c)

    roles =
      Enum.map(c.agent.roles, fn role ->
        %{
          "name" => role.name,
          "provider" => role.provider,
          "model" => if(role.name == "Reviewer", do: "fixture-new", else: role.model)
        }
      end)

    assert {:ok, _} =
             AgentProfiles.update(c.agent, %{
               "instructions" => "New instructions",
               "roles" => roles
             })

    assert {:ok, %{run: receiver}} =
             Handoffs.perform(c.goal.id, command.command_id, perform_opts())

    profile = receiver.extensions["shoestring.agent:binding"]
    assert profile["revision"] == 1
    assert profile["model"] == "fixture-reviewer"
    assert receiver.prompt =~ c.agent.instructions
    refute receiver.prompt =~ "New instructions"
  end

  test "changed command cache refuses before observation", c do
    command = request!(c)

    Repo.update!(
      Ecto.Changeset.change(command,
        result: put_in(command.result, ["receiver_profile", "model"], "fixture-new")
      )
    )

    assert {:error, :plan_handoff_authority_mismatch} =
             Handoffs.perform(
               c.goal.id,
               command.command_id,
               perform_opts(observe: fn _ -> flunk("unauthorized provider probe") end)
             )

    assert run_count(c.goal.id) == 1
  end

  test "injected receiver identity refuses before observation", c do
    command = request!(c)

    assert {:error, :plan_handoff_authority_mismatch} =
             Handoffs.perform(
               c.goal.id,
               command.command_id,
               perform_opts(
                 identity: Shoestring.Harness.Fake.identity(),
                 observe: fn _ -> flunk("unauthorized provider probe") end
               )
             )

    assert run_count(c.goal.id) == 1
  end

  test "forged provenance without a canonical handoff cannot switch a run profile", c do
    {:ok, profile} =
      Shoestring.Cobbler.ExecutionProfile.resolve(
        Map.put(c.run.extensions["shoestring.agent:binding"], "role", "Reviewer"),
        Repo
      )

    extensions =
      c.run.extensions
      |> Map.put("shoestring.agent:binding", profile)
      |> Map.put("cobbler.handoff:handoff_id", Ecto.UUID.generate())

    task = Repo.get!(Shoestring.Trajectory.Task, c.run.task_id)

    request =
      Shoestring.Test.ElvesHelpers.run_request(c.goal, task)
      |> Map.merge(%{
        workspace_ref: c.run.workspace_ref,
        extensions: extensions,
        dispatch_id: extensions["cobbler.handoff:handoff_id"],
        continuation: %{
          checkpoint_id: c.checkpoint.checkpoint_id,
          next_action: c.checkpoint.next_action,
          decision_refs: []
        }
      })

    assert {:error, :plan_continuation_binding_mismatch} =
             Runs.request(request, Shoestring.Harness.ClaudeHeadless.identity(), exec_opts())

    assert run_count(c.goal.id) == 1
  end

  test "role is digest covered and exact command replay preserves receiver identity", c do
    attributes = attrs(c)
    command = request!(c, attributes)
    assert request!(c, attributes).id == command.id

    assert {:error, _} =
             Handoffs.request(
               c.goal.id,
               put_in(attributes, ["payload", "receiver_role"], "Coordinator"),
               now: now()
             )

    assert run_count(c.goal.id) == 1
  end

  @tag handoff_stop: :suspended
  test "a safe-stop request alone cannot authorize handoff", c do
    command = request!(c)
    task = Repo.get!(Shoestring.Trajectory.Task, c.run.task_id)

    request =
      Shoestring.Test.ElvesHelpers.run_request(c.goal, task)
      |> Map.merge(%{
        dispatch_id: command.id,
        workspace_ref: c.run.workspace_ref,
        extensions: Shoestring.Cobbler.PlanHandoff.extensions(c.run, command.result, command.id),
        continuation: %{
          checkpoint_id: c.checkpoint.checkpoint_id,
          next_action: c.checkpoint.next_action,
          decision_refs: []
        }
      })

    assert {:error, :plan_continuation_binding_mismatch} =
             Runs.request(
               request,
               Shoestring.Harness.ClaudeHeadless.identity(),
               exec_opts(run_id: command.id)
             )

    assert {:error, :plan_handoff_parent_not_definitively_stopped} =
             Handoffs.perform(
               c.goal.id,
               command.command_id,
               perform_opts(observe: fn _ -> flunk("probe before definitive stop") end)
             )

    assert run_count(c.goal.id) == 1
    refute Handoffs.permanent_error?(:plan_handoff_parent_not_definitively_stopped)
    terminal(c.goal, c.run, "run.interrupted")

    assert {:ok, %{outcome: :dispatched}} =
             Handoffs.perform(c.goal.id, command.command_id, perform_opts())
  end

  test "live ownership blocks transfer even with a stored terminal", c do
    command = request!(c)

    assert {:error, _} =
             Handoffs.perform(
               c.goal.id,
               command.command_id,
               perform_opts(
                 sender_elf: self(),
                 observe: fn _ -> flunk("probe while sender owned") end
               )
             )

    assert run_count(c.goal.id) == 1
  end

  test "a receiver quota continuation retains the explicitly selected role and original attempt",
       c do
    command = request!(c)

    assert {:ok, %{run: receiver}} =
             Handoffs.perform(c.goal.id, command.command_id, perform_opts())

    checkpoint = %{c.checkpoint | checkpoint_id: Ecto.UUID.generate(), run_id: receiver.id}
    assert {:ok, _} = Shoestring.Harness.Checkpoints.record(c.goal.id, checkpoint, now: now())

    terminal(c.goal, receiver, "run.failed", %{
      "error_category" => "quota_refused",
      "error_code" => "rate_limit_exceeded"
    })

    task = Repo.get!(Shoestring.Trajectory.Task, receiver.task_id)

    request =
      Shoestring.Test.ElvesHelpers.run_request(c.goal, task)
      |> Map.merge(%{
        workspace_ref: receiver.workspace_ref,
        extensions: receiver.extensions,
        continuation: %{
          checkpoint_id: checkpoint.checkpoint_id,
          next_action: checkpoint.next_action,
          decision_refs: []
        }
      })

    assert {:ok, resumed} =
             Runs.request(request, Shoestring.Harness.ClaudeHeadless.identity(), exec_opts())

    assert {:ok, _, _} = Shoestring.Harness.Dispatches.enqueue_for_run(resumed, exec_opts())

    assert resumed.extensions["shoestring.agent:binding"] ==
             receiver.extensions["shoestring.agent:binding"]

    assert {:ok, chains} = PlanRunLineage.load(Repo, c.goal.id)
    assert chains[c.run.id] == [c.run.id, receiver.id, resumed.id]
    complete_run!(c.goal, resumed.id)

    assert {:ok, %{disposition: :accepted}} =
             Cobbler.complete_plan_task_run(c.goal.id, resumed.id, exec_opts())

    assert {:ok, %{accepted: ["alpha"], total_attempts: 1}} =
             Cobbler.plan_execution_status(c.goal.id)
  end

  test "discarded handoff delivery repairs the same receiver intent", c do
    command = request!(c)
    job = Repo.get_by!(Oban.Job, queue: "handoff")
    Repo.update!(Ecto.Changeset.change(job, state: "discarded"))
    assert {:ok, %{repaired_count: 1, failures: []}} = Handoffs.reconcile(now: now())

    assert {:ok, %{outcome: :dispatched, run: receiver}} =
             Handoffs.perform(c.goal.id, command.command_id, perform_opts())

    assert receiver.id == command.id
    assert {:ok, %{repaired_count: 0, failures: []}} = Handoffs.reconcile(now: now())
    assert {:ok, %{total_attempts: 1}} = Cobbler.plan_execution_status(c.goal.id)
  end

  test "receiver quota refusal records a decision and creates no fallback run", c do
    command = request!(c)
    observe = perform_opts()[:observe]

    assert {:ok, %{outcome: :refused, decision_result: result}} =
             Handoffs.perform(
               c.goal.id,
               command.command_id,
               perform_opts(
                 observe: fn scope ->
                   {:ok, snapshot} = observe.(scope)

                   {:ok,
                    %{
                      snapshot
                      | windows: Enum.map(snapshot.windows, &Map.put(&1, :used_percent, 100.0))
                    }}
                 end
               )
             )

    refute result == :admit
    assert run_count(c.goal.id) == 1
    assert {:ok, %{total_attempts: 1}} = Cobbler.plan_execution_status(c.goal.id)
    assert {:ok, %{repaired_count: 0, failures: []}} = Handoffs.reconcile(now: now())
  end

  test "a new approval blocks the old handoff before receiver observation", c do
    command = request!(c)

    assert {:ok, %{revision: revision}} =
             Shoestring.Cobbler.Plans.propose(
               c.goal.id,
               Shoestring.Test.PlanFixtures.propose_attrs(
                 plan: chain_plan(),
                 parent_revision_number: 1,
                 proposal_id: "fixture-amendment"
               ),
               exec_opts()
             )

    assert {:ok, _} =
             Shoestring.Cobbler.Plans.approve(
               c.goal.id,
               Shoestring.Test.PlanFixtures.approve_attrs(2, revision.digest,
                 decision_id: "fixture-amendment-approval"
               ),
               exec_opts()
             )

    assert {:error, :plan_authority_changed} =
             Handoffs.perform(
               c.goal.id,
               command.command_id,
               perform_opts(observe: fn _ -> flunk("probe under stale approval") end)
             )

    assert run_count(c.goal.id) == 1
  end

  @tag handoff_stop: :exhausted
  test "duration exhaustion blocks receiver observation without resetting the attempt", c do
    command = request!(c)

    assert {:error, :task_duration_exhausted} =
             Handoffs.perform(
               c.goal.id,
               command.command_id,
               perform_opts(observe: fn _ -> flunk("probe after duration exhaustion") end)
             )

    assert {:ok, %{total_attempts: 1, total_run_duration_ms: 1_200_000}} =
             Cobbler.plan_execution_status(c.goal.id)

    assert run_count(c.goal.id) == 1
  end

  test "durable workers deliver the pinned receiver model to a supervised Fake", c do
    command = request!(c)
    supervisor = start_supervised!({Shoestring.Elves.Supervisor, name: nil})

    env = [
      dispatch_clock: Shoestring.Test.PlanHandoffClock,
      handoff_observe: perform_opts()[:observe],
      dispatch_effect: Shoestring.Harness.Dispatch.ElfEffect,
      elf_dispatch_opts: [
        supervisor: supervisor,
        adapter: Shoestring.Test.ProfileCaptureFake,
        process_owner: :runner,
        command: ["cat"],
        clock: Shoestring.Test.PlanHandoffClock,
        notify: self(),
        adapter_opts: %{
          model: "wrong-model",
          args: ["--model", "wrong-model"],
          observer: self(),
          scenario: Shoestring.Harness.Fake.Scenario.normal_completion()
        },
        runner_opts: [kill_grace_ms: 200, reap_timeout_ms: 2000]
      ]
    ]

    previous = Enum.map(env, fn {key, _} -> {key, Application.fetch_env(:shoestring, key)} end)
    Enum.each(env, fn {key, value} -> Application.put_env(:shoestring, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:shoestring, key, value)
        {key, :error} -> Application.delete_env(:shoestring, key)
      end)
    end)

    job = Repo.get_by!(Oban.Job, queue: "handoff")
    assert :ok = Shoestring.Cobbler.HandoffWorker.perform(job)
    dispatch = Repo.get_by!(Shoestring.Harness.DispatchRecord, run_id: command.id)

    assert :ok =
             Shoestring.Harness.DispatchWorker.perform(%Oban.Job{
               args: %{"dispatch_id" => dispatch.dispatch_id}
             })

    assert_receive {:profile_started, pid, ref, request, options}, 2000
    monitor = Process.monitor(pid)
    assert options.model == "fixture-reviewer"
    refute Map.has_key?(options, :args)
    assert request.extensions["shoestring.agent:binding"]["role"] == "Reviewer"
    send(pid, {:continue_profile, ref})
    receiver_id = command.id
    assert_receive {:elf_terminal, ^receiver_id, %{class: :completed}}, 2000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2000

    assert {:ok, %{disposition: :accepted}} =
             Cobbler.complete_plan_task_run(c.goal.id, receiver_id, exec_opts())

    assert {:ok, %{accepted: ["alpha"], total_attempts: 1}} =
             Cobbler.plan_execution_status(c.goal.id)
  end
end
