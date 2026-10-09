defmodule Shoestring.Cobbler.ExecutionProfileTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.{AgentProfiles, Cobbler}
  alias Shoestring.Test.CobblerHelpers
  import Shoestring.Test.PlanExecutorHelpers

  setup do
    settings = AgentProfiles.settings()

    assert {:ok, _} =
             AgentProfiles.save_settings(settings, %{
               "codex_models" => "fixture-model-v1 fixture-model-v2",
               "claude_models" => "default fixture-claude"
             })

    attrs = Shoestring.ConfigurationFixtures.agent_attrs()

    roles =
      Enum.map(attrs["roles"], fn role ->
        cond do
          role["provider"] == "codex" -> Map.put(role, "model", "fixture-model-v1")
          role["name"] == "Reviewer" -> Map.put(role, "model", "fixture-claude")
          true -> role
        end
      end)

    assert {:ok, agent} = AgentProfiles.create(Map.put(attrs, "roles", roles))
    assert {:ok, snapshot} = AgentProfiles.snapshot_by_id(agent.id)
    profile = Map.put(Map.take(snapshot, ["profile_id", "revision", "digest"]), "role", "Worker")
    goal = CobblerHelpers.create_goal!()
    revision = propose_and_approve!(goal)
    %{agent: agent, goal: goal, revision: revision, profile: profile}
  end

  defp admitted(goal, adapter \\ "codex_app_server_stdio") do
    original = admit!(goal)
    payload = put_in(original.payload, ["candidate", "adapter_id"], adapter)
    payload = Map.put(payload, "decision_id", Ecto.UUID.generate())
    CobblerHelpers.append_admission_event!(goal.id, payload)
  end

  defp request(goal, revision, profile, admission) do
    Cobbler.request_plan_execution(
      goal.id,
      %{
        revision_number: revision.revision_number,
        digest: revision.digest,
        admission_event_id: admission.id,
        agent_profile: profile
      },
      exec_opts()
    )
  end

  test "saved profile remains pinned after edits and supplied launch identity cannot replace it",
       c do
    admission = admitted(c.goal)
    assert {:ok, _} = request(c.goal, c.revision, c.profile, admission)

    roles =
      Enum.map(c.agent.roles, fn role ->
        %{
          "name" => role.name,
          "provider" => role.provider,
          "model" => if(role.provider == "codex", do: "fixture-model-v2", else: role.model)
        }
      end)

    assert {:ok, _} =
             AgentProfiles.update(c.agent, %{
               "instructions" => "New instructions",
               "roles" => roles
             })

    assert {:ok, status} = Cobbler.plan_execution_status(c.goal.id)
    assert %{agent_profile: %{"revision" => 1, "model" => "fixture-model-v1"}} = status.execution
    assert status.execution.agent_profile["revision"] == 1
    assert status.execution.agent_profile["model"] == "fixture-model-v1"

    assert {:ok, run} =
             Cobbler.advance_plan_execution(
               c.goal.id,
               exec_opts(
                 admission_event_id: admission.id,
                 grant_lease_extra: [identity: Shoestring.Harness.Fake.identity()]
               )
             )

    stored = Repo.get!(Shoestring.Harness.RunRecord, run.run_id)
    assert stored.provider_id == "codex_app_server_stdio"
    assert stored.extensions["shoestring.agent:binding"] == status.execution.agent_profile
    assert stored.prompt =~ c.agent.instructions
    refute stored.prompt =~ "New instructions"
  end

  test "a mismatched admission cannot activate the requested profile", c do
    admission = admitted(c.goal, "claude_headless_stream_json")

    assert {:error, :execution_profile_admission_mismatch} =
             request(c.goal, c.revision, c.profile, admission)

    assert {:ok, %{planned?: false}} = Cobbler.plan_execution_status(c.goal.id)
    assert run_count(c.goal.id) == 0
  end

  test "a subsequent task admission must still match the pinned provider", c do
    admission = admitted(c.goal)
    assert {:ok, _} = request(c.goal, c.revision, c.profile, admission)
    wrong = admitted(c.goal, "claude_headless_stream_json")

    assert {:error, :execution_profile_admission_mismatch} =
             Cobbler.advance_plan_execution(c.goal.id, exec_opts(admission_event_id: wrong.id))

    assert run_count(c.goal.id) == 0
  end

  test "profile digest or selection cannot change when replaying an activation", c do
    admission = admitted(c.goal)
    stale = Map.put(c.profile, "digest", String.duplicate("0", 64))
    assert {:error, :invalid_execution_profile} = request(c.goal, c.revision, stale, admission)
    assert {:ok, _} = request(c.goal, c.revision, c.profile, admission)
    assert {:ok, %{outcome: :replayed}} = request(c.goal, c.revision, c.profile, admission)
    selected = Map.put(c.profile, "role", "Reviewer")
    reviewer = admitted(c.goal, "claude_headless_stream_json")

    reviewer_payload =
      put_in(reviewer.payload, ["candidate", "provider_id"], "claude")
      |> Map.put("decision_id", Ecto.UUID.generate())

    reviewer = CobblerHelpers.append_admission_event!(c.goal.id, reviewer_payload)

    assert {:error, :execution_request_conflict} =
             request(c.goal, c.revision, selected, reviewer)

    assert {:ok, status} = Cobbler.plan_execution_status(c.goal.id)
    assert status.execution.agent_profile["role"] == "Worker"
  end

  test "provider default is refused because it cannot pin a selected model", c do
    admission = admitted(c.goal)
    selected = Map.put(c.profile, "role", "Coordinator")

    assert {:error, :explicit_execution_model_required} =
             request(c.goal, c.revision, selected, admission)

    assert run_count(c.goal.id) == 0
  end

  test "delivery pins the stored model after runtime options change", c do
    admission = admitted(c.goal)
    assert {:ok, _} = request(c.goal, c.revision, c.profile, admission)

    assert {:ok, run} =
             Cobbler.advance_plan_execution(
               c.goal.id,
               exec_opts(admission_event_id: admission.id)
             )

    stored = Repo.get!(Shoestring.Harness.RunRecord, run.run_id)
    dispatch = Repo.get_by!(Shoestring.Harness.DispatchRecord, run_id: stored.id)
    supervisor = start_supervised!({Shoestring.Elves.Supervisor, name: nil})
    previous = Application.get_env(:shoestring, :elf_dispatch_opts)

    Application.put_env(:shoestring, :elf_dispatch_opts,
      supervisor: supervisor,
      adapter: Shoestring.Test.ProfileCaptureFake,
      process_owner: :runner,
      command: ["cat"],
      clock: Shoestring.Test.FixedClock,
      notify: self(),
      adapter_opts: %{
        model: "wrong-model",
        args: ["--model", "wrong-model"],
        observer: self(),
        scenario: Shoestring.Harness.Fake.Scenario.normal_completion()
      },
      runner_opts: [kill_grace_ms: 200, reap_timeout_ms: 2000]
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:shoestring, :elf_dispatch_opts, previous),
        else: Application.delete_env(:shoestring, :elf_dispatch_opts)
    end)

    assert :ok = Shoestring.Harness.Dispatch.ElfEffect.perform(stored, dispatch)
    assert_receive {:profile_started, pid, ref, delivered, opts}, 2000
    monitor = Process.monitor(pid)
    assert opts.model == "fixture-model-v1"
    refute Map.has_key?(opts, :args)
    assert delivered.extensions["shoestring.agent:binding"]["digest"] == c.profile["digest"]
    send(pid, {:continue_profile, ref})
    id = stored.id
    assert_receive {:elf_terminal, ^id, %{class: :completed}}, 2000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2000
  end
end
