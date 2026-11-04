defmodule Shoestring.Cobbler.ParallelDispatchCharacterizationTest do
  @moduledoc """
  Characterization at Settings' parallel tasks 1 (the default): one
  single-task dispatch takes the single global task claim, holds no
  reservation, and records the ordinary dispatch events. Parallel tasks 1
  must behave exactly as before separate dispatches could run side by side.
  Hermetic: the Fake provider's identity and an injected gate runner.
  """
  use Shoestring.DataCase, async: false
  import Ecto.Query

  alias Shoestring.Cobbler.{Commands, Parallelism, PlanExecutor, ReservationRecord}
  alias Shoestring.Harness.Fake
  alias Shoestring.Test.{CobblerHelpers, PlanExecutorHelpers, PlanFixtures, PlanHandoffClock}
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Trajectory.TrajectoryEvent

  @now PlanExecutorHelpers.now()

  @dispatch_types ~w(cobbler.claim.acquired run.requested lease.proposed lease.granted lease.active dispatch.requested cobbler.plan.task.dispatched)

  defp single_plan do
    %{
      "version" => 1,
      "goal" => PlanFixtures.goal(),
      "budget" => %{"max_total_attempts" => 6, "max_total_duration_seconds" => 7_200},
      "tasks" => [PlanFixtures.task("only", "Do the only thing", [])]
    }
  end

  defp admission!(goal) do
    snapshot_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, snapshot_id)

    payload =
      CobblerHelpers.admission_payload(
        provider_id: "fake",
        adapter_id: Fake.identity().adapter_id
      )
      |> Map.merge(%{
        "evaluated_at" => DateTime.to_iso8601(@now),
        "observation" => %{
          "snapshot_id" => snapshot_id,
          "confidence" => "high",
          "freshness" => "fresh"
        },
        "proposed_bounds" => %{
          "response_budget" => 10,
          "tool_budget" => 25,
          "checkpoint_cadence" => 1,
          "reserves" => %{"response" => 1, "tool" => 1},
          "deadline" => DateTime.to_iso8601(DateTime.add(@now, 300))
        }
      })

    CobblerHelpers.append_admission_event!(goal.id, payload)
  end

  test "at parallel tasks 1 a single dispatch takes the global claim and no reservation" do
    assert Parallelism.tasks() == 1
    assert Parallelism.policy() == nil

    goal = CobblerHelpers.create_goal!()
    revision = PlanExecutorHelpers.propose_and_approve!(goal, single_plan())
    admission = admission!(goal)

    opts =
      PlanExecutorHelpers.exec_opts(clock: PlanHandoffClock, admission_event_id: admission.id)

    assert {:ok, _} =
             PlanExecutor.request_execution(
               goal.id,
               Map.put(revision, :admission_event_id, admission.id),
               opts
             )

    assert {:ok, %{disposition: :dispatched}} = PlanExecutor.advance(goal.id, opts)

    types =
      Repo.all(
        from e in TrajectoryEvent,
          where: e.goal_id == ^goal.id,
          order_by: [asc: e.sequence],
          select: e.type
      )

    for type <- @dispatch_types, do: assert(type in types)

    assert types |> Enum.filter(&(&1 in @dispatch_types)) |> List.last() ==
             "cobbler.plan.task.dispatched"

    refute Enum.any?(types, &String.starts_with?(&1, "cobbler.reservation"))

    assert %{status: "resolved", result: %{"kind" => "claimed"}} =
             Commands.get(goal.id, "plan-only-1")

    assert Commands.active_claim().goal_id == goal.id
    assert Repo.aggregate(ReservationRecord, :count) == 0
  end
end
