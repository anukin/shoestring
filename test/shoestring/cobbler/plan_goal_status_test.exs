defmodule Shoestring.Cobbler.PlanGoalStatusTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.Cobbler.PlanGoalStatus
  alias Shoestring.Test.CobblerHelpers
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{Goal, Projector, TrajectoryEvent}

  @digest String.duplicate("a", 64)
  @now ~U[2026-09-30 12:00:00.000000Z]

  defp append(goal, type, execution_id, key \\ nil) do
    payload =
      case type do
        "cobbler.plan.execution.requested" ->
          %{
            "execution_id" => execution_id,
            "revision_number" => 1,
            "plan_digest" => @digest,
            "ordered_task_ids" => ["alpha"]
          }

        "cobbler.plan.execution.completed" ->
          %{
            "execution_id" => execution_id,
            "revision_number" => 1,
            "plan_digest" => @digest,
            "commit" => String.duplicate("b", 40)
          }
      end

    Trajectory.append(goal.id, %{
      "type" => type,
      "schema_version" => 1,
      "actor" => "cobbler",
      "occurred_at" => @now,
      "idempotency_key" => key || "#{type}:#{execution_id}",
      "payload" => payload
    })
  end

  defp status(goal), do: Repo.get!(Goal, goal.id).status

  test "completion completes the row; a later execution request reopens it" do
    goal = CobblerHelpers.create_goal!()
    [first, second] = [Ecto.UUID.generate(), Ecto.UUID.generate()]

    assert {:ok, _} = append(goal, "cobbler.plan.execution.requested", first)
    assert status(goal) == "active"
    assert {:ok, completed} = append(goal, "cobbler.plan.execution.completed", first)
    assert status(goal) == "completed"

    # An idempotent replay of the same completion converges on the same row.
    assert {:ok, ^completed} = append(goal, "cobbler.plan.execution.completed", first)
    assert status(goal) == "completed"

    assert {:ok, _} = append(goal, "cobbler.plan.execution.requested", second)
    assert status(goal) == "active"
  end

  test "a completion for a superseded execution is refused without changing the row" do
    goal = CobblerHelpers.create_goal!()
    [stale, current] = [Ecto.UUID.generate(), Ecto.UUID.generate()]
    assert {:ok, _} = append(goal, "cobbler.plan.execution.requested", stale)
    assert {:ok, _} = append(goal, "cobbler.plan.execution.requested", current)

    assert {:error, :stale_plan_execution_completion} =
             append(goal, "cobbler.plan.execution.completed", stale)

    assert status(goal) == "active"

    refute Repo.exists?(
             from e in TrajectoryEvent, where: e.type == "cobbler.plan.execution.completed"
           )
  end

  test "archived goals are never moved by plan facts" do
    goal = CobblerHelpers.create_goal!()
    Repo.update!(Ecto.Changeset.change(goal, status: "archived"))
    execution_id = Ecto.UUID.generate()
    assert {:ok, _} = append(goal, "cobbler.plan.execution.requested", execution_id)
    assert {:ok, _} = append(goal, "cobbler.plan.execution.completed", execution_id)
    assert status(goal) == "archived"
    assert {:ok, :unchanged} = PlanGoalStatus.sync(goal.id)
  end

  test "startup repair re-derives historical rows in bounded pages, idempotently" do
    unplanned = CobblerHelpers.create_goal!()
    completed = CobblerHelpers.create_goal!()
    reopened = CobblerHelpers.create_goal!()
    [a, b, c] = [Ecto.UUID.generate(), Ecto.UUID.generate(), Ecto.UUID.generate()]
    assert {:ok, _} = append(completed, "cobbler.plan.execution.requested", a)
    assert {:ok, _} = append(completed, "cobbler.plan.execution.completed", a)
    assert {:ok, _} = append(reopened, "cobbler.plan.execution.requested", b)
    assert {:ok, _} = append(reopened, "cobbler.plan.execution.completed", b)
    assert {:ok, _} = append(reopened, "cobbler.plan.execution.requested", c)

    # Simulate rows written before synchronization existed.
    Repo.update_all(from(g in Goal, where: g.id == ^completed.id), set: [status: "active"])
    Repo.update_all(from(g in Goal, where: g.id == ^reopened.id), set: [status: "completed"])

    assert {:ok, %{checked_count: 2, repaired_count: 2, failure_count: 0, failures: []}} =
             PlanGoalStatus.reconcile()

    assert {status(unplanned), status(completed), status(reopened)} ==
             {"active", "completed", "active"}

    assert {:ok, %{repaired_count: 0}} = PlanGoalStatus.reconcile()
    assert {:ok, :unplanned} = PlanGoalStatus.sync(unplanned.id)
  end

  test "the goal/task projector rebuild derives the same status as the writer" do
    goal = CobblerHelpers.create_goal!()

    {:ok, _} =
      Trajectory.append(goal.id, %{
        "type" => "goal.created",
        "schema_version" => 1,
        "actor" => "test",
        "occurred_at" => @now,
        "payload" => %{"title" => goal.title}
      })

    execution_id = Ecto.UUID.generate()
    assert {:ok, _} = append(goal, "cobbler.plan.execution.requested", execution_id)
    assert {:ok, _} = append(goal, "cobbler.plan.execution.completed", execution_id)
    assert status(goal) == "completed"

    assert {:ok, _} = Projector.rebuild(goal.id)
    assert status(goal) == "completed"

    events =
      Repo.all(from e in TrajectoryEvent, where: e.goal_id == ^goal.id, order_by: e.sequence)

    assert {:ok, %{goal: %Goal{status: "completed"}}} = Projector.replay_events(goal, events)
  end
end
