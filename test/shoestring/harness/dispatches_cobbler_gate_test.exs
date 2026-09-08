defmodule Shoestring.Harness.DispatchesCobblerGateTest do
  @moduledoc """
  Hermetic regression tests for the opt-in Cobbler gate on the direct
  dispatch path: `Dispatches.enqueue/3` with `require_cobbler_command: true`
  rejects goals that hold no live exclusive claim instead of bypassing
  commands, admits goals that do, and stays off by default.
  """
  use Shoestring.DataCase, async: false
  use Oban.Testing, repo: Shoestring.Repo, engine: Oban.Engines.Lite

  alias Shoestring.Harness.{DispatchWorker, Identity, RunRequest, RunRecord}
  alias Shoestring.Harness.Dispatches
  alias Shoestring.Repo
  alias Shoestring.Trajectory.{Goal, Task}

  import Shoestring.Test.CobblerHelpers

  setup do
    goal = insert_goal()
    task = insert_task(goal)
    {:ok, goal: goal, task: task}
  end

  test "gated enqueue is rejected when the goal holds no claim", %{goal: goal, task: task} do
    assert {:error, {:no_claimed_command, detail}} =
             Dispatches.enqueue(run_request(goal, task), identity(), gated_opts())

    assert detail.goal_id == goal.id
    assert detail.reason == :no_active_claim

    # Protected: nothing was persisted and no job was enqueued.
    refute Repo.exists?(from run in RunRecord, where: run.goal_id == ^goal.id)
    assert [] = all_enqueued(worker: DispatchWorker)
  end

  test "gated enqueue proceeds when the goal holds the live claim", %{
    goal: goal,
    task: task
  } do
    admission = append_admission_event!(goal.id)

    assert {:ok, %{outcome: :recorded}} =
             Shoestring.Cobbler.Commands.submit(
               goal.id,
               claim_command(admission, command_id: "cmd-gate-claim"),
               now: now()
             )

    assert {:ok, dispatch, job} =
             Dispatches.enqueue(run_request(goal, task), identity(), gated_opts())

    assert dispatch.status == "requested"
    assert job.args["dispatch_id"] == dispatch.dispatch_id
  end

  test "gated enqueue rejects when another goal holds the claim", %{
    goal: goal,
    task: task
  } do
    holder = create_goal!()
    holder_admission = append_admission_event!(holder.id)

    assert {:ok, %{outcome: :recorded}} =
             Shoestring.Cobbler.Commands.submit(
               holder.id,
               claim_command(holder_admission, command_id: "cmd-gate-holder"),
               now: now()
             )

    assert {:error, {:no_claimed_command, detail}} =
             Dispatches.enqueue(run_request(goal, task), identity(), gated_opts())

    assert detail.reason == :claim_held_by_other_goal
    assert detail.holder == holder.id
  end

  test "ungated enqueue still proceeds without a claim (opt-in documented)", %{
    goal: goal,
    task: task
  } do
    assert {:ok, dispatch, _job} =
             Dispatches.enqueue(run_request(goal, task), identity(), base_opts())

    assert dispatch.status == "requested"
  end

  defp gated_opts, do: Keyword.put(base_opts(), :require_cobbler_command, true)

  defp base_opts do
    [clock: Shoestring.Test.FixedClock, identifier: Shoestring.Test.FixedIdentifier]
  end

  defp run_request(goal, task) do
    assert {:ok, request} =
             RunRequest.new(%{
               version: 1,
               goal_id: goal.id,
               task_id: task.id,
               workspace_ref: "workspace/project",
               prompt: "Dispatch a deterministic fake run.",
               policy: %{mode: "supervised", network: false, write_access: true},
               requested_capabilities: [],
               dispatch_id: Ecto.UUID.generate(),
               extensions: %{}
             })

    request
  end

  defp identity do
    assert {:ok, identity} =
             Identity.new(%{
               adapter_id: "test.adapter",
               provider: "test",
               adapter_version: "1.0.0",
               schema_version: 1,
               invocation_mode: :fake
             })

    identity
  end

  defp insert_goal do
    %Goal{}
    |> Goal.changeset(%{"title" => "Gate goal"})
    |> Ecto.Changeset.put_change(:id, Ecto.UUID.generate())
    |> Ecto.Changeset.put_change(:owner_id, Ecto.UUID.generate())
    |> Repo.insert!()
  end

  defp insert_task(goal) do
    %Task{}
    |> Task.changeset(%{"title" => "Gate task"})
    |> Ecto.Changeset.put_change(:id, Ecto.UUID.generate())
    |> Ecto.Changeset.put_change(:goal_id, goal.id)
    |> Repo.insert!()
  end
end
