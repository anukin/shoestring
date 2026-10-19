defmodule Shoestring.Cobbler.ExecutionAdmissionWaitingTest do
  @moduledoc """
  An admission that fails before any decision (no capacity reading for the
  provider) is recorded once per attempt and reason, so `follow` can say why
  a task is not starting. No provider, no monitor.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.CLI.Follow
  alias Shoestring.Cobbler.ExecutionAdmission
  alias Shoestring.Test.CobblerHelpers
  alias Shoestring.Trajectory.TrajectoryEvent

  test "a missing capacity reading is recorded once and explained" do
    goal = CobblerHelpers.create_goal!()

    execution = %{
      execution_id: Ecto.UUID.generate(),
      agent_profile: %{"provider" => "nobody-#{System.unique_integer([:positive])}"}
    }

    task = %{"id" => "alpha", "execution" => %{"max_duration_seconds" => 300}}

    for _ <- 1..3 do
      assert {:error, {:execution_admission_blocked, reason}} =
               ExecutionAdmission.admit(goal.id, execution, task, 1)

      assert reason in [:no_observation, :no_observation_for_provider]
    end

    assert [waiting] = waiting(goal.id)
    assert waiting.payload["plan_task_id"] == "alpha"
    assert waiting.payload["attempt"] == 1
    assert waiting.payload["reason"] in ["no_observation", "no_observation_for_provider"]

    line = Follow.line(%{type: waiting.type, payload: waiting.payload})
    assert line =~ "Task alpha is waiting: no capacity reading for nobody-"
    assert line =~ "capacity_monitors"

    # A later attempt is a new wait.
    assert {:error, _} = ExecutionAdmission.admit(goal.id, execution, task, 2)
    assert length(waiting(goal.id)) == 2

    refute Repo.exists?(
             from e in TrajectoryEvent,
               where: e.type == "admission.decided" and e.goal_id == ^goal.id
           )
  end

  defp waiting(goal_id) do
    Repo.all(
      from e in TrajectoryEvent,
        where: e.goal_id == ^goal_id and e.type == "cobbler.plan.admission.waiting",
        order_by: e.sequence
    )
  end
end
