defmodule Mix.Tasks.Shoestring.ExecutionHandoffTest do
  use Shoestring.DataCase, async: false
  import Shoestring.Test.PlanHandoffHelpers
  alias Shoestring.Cobbler.ExecutionControl

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
    c = fixture()
    {:ok, status} = ExecutionControl.status(c.goal.id)
    Map.put(c, :execution_id, status.execution.execution_id)
  end

  defp args(c) do
    references = attrs(c)["payload"]["decision_refs"] |> Enum.flat_map(&["--decision-ref", &1])

    [
      "handoff",
      c.goal.id,
      "--execution-id",
      c.execution_id,
      "--run-id",
      c.run.id,
      "--checkpoint-id",
      c.checkpoint.checkpoint_id,
      "--role",
      "Reviewer",
      "--scope",
      "fixture-scope",
      "--command-id",
      "fixture-cli-handoff",
      "--reason",
      "Continue the stopped task",
      "--by",
      "human:operator"
    ] ++ references
  end

  test "CLI queues an exact role-bound handoff without starting its receiver", c do
    Mix.Tasks.Shoestring.Execution.run(["status", c.goal.id])
    assert_receive {:mix_shell, :info, [status_json]}
    status = Jason.decode!(status_json)
    assert status["active_continuation"]["checkpoint_id"] == c.checkpoint.checkpoint_id
    assert status["active_continuation"]["decision_refs"] == attrs(c)["payload"]["decision_refs"]
    assert status["active_continuation"]["agent_profile"]["role"] == "Worker"
    arguments = args(c)
    Mix.Tasks.Shoestring.Execution.run(arguments)
    assert_receive {:mix_shell, :info, [json]}
    output = Jason.decode!(json)
    assert output["command"]["status"] == "resolved"
    assert output["command"]["result"]["receiver_profile"]["model"] == "fixture-reviewer"
    assert Shoestring.Test.PlanExecutorHelpers.run_count(c.goal.id) == 1
    assert Repo.aggregate(Oban.Job, :count) == 2
    Mix.Tasks.Shoestring.Execution.run(arguments)
    assert_receive {:mix_shell, :info, [replayed]}
    assert Jason.decode!(replayed)["command"]["id"] == output["command"]["id"]
    assert Repo.aggregate(Oban.Job, :count) == 2
    command_id = output["command"]["command_id"]

    assert {:ok, %{outcome: :dispatched}} =
             Shoestring.Cobbler.Handoffs.perform(c.goal.id, command_id, perform_opts())

    Mix.Tasks.Shoestring.Execution.run(arguments)
    assert_receive {:mix_shell, :info, [after_delivery]}
    assert Jason.decode!(after_delivery)["command"]["id"] == output["command"]["id"]
    assert Shoestring.Test.PlanExecutorHelpers.run_count(c.goal.id) == 2
    assert {:ok, status} = ExecutionControl.status(c.goal.id)
    assert status.active_continuation.agent_profile["role"] == "Reviewer"
  end

  test "CLI refuses moving execution, missing refs and duplicate options without queueing", c do
    assert_raise Mix.Error, fn ->
      Mix.Tasks.Shoestring.Execution.run(List.replace_at(args(c), 3, Ecto.UUID.generate()))
    end

    assert_raise Mix.Error, fn ->
      Mix.Tasks.Shoestring.Execution.run(args(c) ++ ["--role", "Worker"])
    end

    assert_raise Mix.Error, fn -> Mix.Tasks.Shoestring.Execution.run(Enum.take(args(c), 18)) end
    assert Repo.aggregate(Oban.Job, :count) == 1

    assert {:error, :handoff_execution_request_mismatch} =
             ExecutionControl.handoff(c.goal.id, %{
               requested_by: "human:operator",
               run_id: "invalid",
               execution_id: c.execution_id,
               command_id: "fixture-cli-handoff"
             })
  end

  test "handoff on a goal without execution returns a structured refusal" do
    goal = Shoestring.Test.CobblerHelpers.create_goal!()

    assert {:error, :handoff_execution_request_mismatch} =
             ExecutionControl.handoff(goal.id, %{requested_by: "human:operator"})
  end
end
