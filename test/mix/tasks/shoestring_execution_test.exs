defmodule Mix.Tasks.Shoestring.ExecutionTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.{AgentProfiles, Cobbler}
  alias Shoestring.Cobbler.{ExecutionControl, PlanExecutionWorker}
  import Shoestring.Test.PlanExecutorHelpers

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)

    assert {:ok, _} =
             AgentProfiles.save_settings(AgentProfiles.settings(), %{
               "codex_models" => "fixture-model"
             })

    attrs = Shoestring.ConfigurationFixtures.agent_attrs()

    roles =
      Enum.map(attrs["roles"], fn role ->
        if role["provider"] == "codex", do: Map.put(role, "model", "fixture-model"), else: role
      end)

    assert {:ok, agent} = AgentProfiles.create(Map.put(attrs, "roles", roles))
    assert {:ok, profile} = AgentProfiles.snapshot_by_id(agent.id)
    goal = Shoestring.Test.CobblerHelpers.create_goal!()
    revision = propose_and_approve!(goal)
    %{goal: goal, revision: revision, profile: profile}
  end

  defp cli(args) do
    Mix.Tasks.Shoestring.Execution.run(args)
    assert_receive {:mix_shell, :info, [json]}
    Jason.decode!(json)
  end

  defp args(c) do
    [
      "start",
      c.goal.id,
      "--revision",
      "1",
      "--digest",
      c.revision.digest,
      "--repo",
      File.cwd!(),
      "--agent",
      c.profile["profile_id"],
      "--agent-revision",
      "1",
      "--agent-digest",
      c.profile["digest"],
      "--role",
      "Worker",
      "--by",
      "human:operator"
    ]
  end

  test "CLI queues a bound durable request without starting providers or dispatch", c do
    result = cli(args(c))
    job = Repo.get!(Oban.Job, result["job_id"])
    execution_id = result["execution"]["execution_id"]
    assert job.args == %{"goal_id" => c.goal.id, "execution_id" => execution_id}
    assert job.queue == "plan_execution"
    assert run_count(c.goal.id) == 0
    assert Repo.aggregate(Shoestring.Harness.DispatchRecord, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 1
    assert cli(args(c))["job_id"] == job.id
    assert cli(["continue", c.goal.id, "--execution-id", execution_id])["job_id"] == job.id
    view = cli(["status", c.goal.id])
    assert view["execution"]["agent_profile"]["model"] == "fixture-model"
    assert view["execution"]["repository_path"] == File.cwd!()
    assert view["execution"]["requested_by"] == "human:operator"
  end

  test "stale approval and changed execution configuration cannot leave queued work", c do
    stale = List.replace_at(args(c), 5, String.duplicate("0", 64))
    assert_raise Mix.Error, ~r/authority_mismatch/, fn -> cli(stale) end
    assert Repo.aggregate(Oban.Job, :count) == 0
    assert {:ok, %{planned?: false}} = Cobbler.plan_execution_status(c.goal.id)
    cli(args(c))
    changed = List.replace_at(args(c), 15, "Reviewer")
    assert_raise Mix.Error, fn -> cli(changed) end
    assert Repo.aggregate(Oban.Job, :count) == 1

    assert {:error, :execution_request_mismatch} =
             ExecutionControl.continue(c.goal.id, Ecto.UUID.generate())
  end

  test "worker with no matching observation waits without allocating a run", c do
    result = cli(args(c))
    job = Repo.get!(Oban.Job, result["job_id"])
    assert {:snooze, 60} = PlanExecutionWorker.perform(job)
    assert run_count(c.goal.id) == 0
    view = cli(["status", c.goal.id])
    assert view["capacity_observation"]["availability"] == "missing"
    assert view["capacity_observation"]["source"] == "cached_observatory"
    assert view["capacity_observation"]["reason"] == "no_observation"

    assert {:cancel, :execution_request_mismatch} =
             PlanExecutionWorker.perform(%Oban.Job{
               args: Map.put(job.args, "execution_id", Ecto.UUID.generate())
             })
  end

  test "startup repair recreates a discarded delivery, preserving execution and counters", c do
    result = cli(args(c))
    job = Repo.get!(Oban.Job, result["job_id"])
    assert {:ok, %{repaired_count: 0, failures: []}} = ExecutionControl.reconcile()
    job |> Ecto.Changeset.change(state: "discarded") |> Repo.update!()
    assert {:ok, %{repaired_count: 1, failures: []}} = ExecutionControl.reconcile()
    assert {:ok, %{repaired_count: 0, failures: []}} = ExecutionControl.reconcile()
    assert {:ok, view} = ExecutionControl.status(c.goal.id)
    assert view.execution.execution_id == result["execution"]["execution_id"]
    assert view.total_attempts == 0
    assert view.total_gate_duration_ms == 0
    assert run_count(c.goal.id) == 0
    assert Repo.aggregate(Oban.Job, :count) == 2
  end

  test "unknown goals are refused before status or delivery" do
    assert_raise Mix.Error, ~r/Goal not found/, fn -> cli(["status", Ecto.UUID.generate()]) end
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "duplicate and unknown CLI options are refused before mutation", c do
    assert_raise Mix.Error, fn -> cli(args(c) ++ ["--revision", "1"]) end
    assert_raise Mix.Error, fn -> cli(["status", c.goal.id, "--force"]) end
    assert Repo.aggregate(Oban.Job, :count) == 0
  end
end
