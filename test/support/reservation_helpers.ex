defmodule Shoestring.Test.ReservationHelpers do
  @moduledoc "Synthetic approved-plan reservation fixtures; no provider process or network."
  import ExUnit.Assertions
  alias Shoestring.Cobbler.{PlanExecutor, ReservationPolicy, ReservationRecord, Reservations}
  alias Shoestring.Harness.{Fake, RunRecord}
  alias Shoestring.Test.{CobblerHelpers, PlanExecutorHelpers, PlanHandoffClock}
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Repo

  def fixture(mode \\ :intent) do
    goal = CobblerHelpers.create_goal!()
    revision = PlanExecutorHelpers.propose_and_approve!(goal)
    now = PlanExecutorHelpers.now()
    snapshot_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, snapshot_id)

    payload =
      CobblerHelpers.admission_payload(
        provider_id: "fake",
        adapter_id: Fake.identity().adapter_id
      )
      |> Map.merge(%{
        "evaluated_at" => DateTime.to_iso8601(now),
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
          "deadline" => DateTime.to_iso8601(DateTime.add(now, 300))
        }
      })

    admission = CobblerHelpers.append_admission_event!(goal.id, payload)

    opts =
      PlanExecutorHelpers.exec_opts(
        clock: PlanHandoffClock,
        admission_event_id: admission.id,
        reservation_policy: %{}
      )

    assert {:ok, _} =
             PlanExecutor.request_execution(
               goal.id,
               Map.put(revision, :admission_event_id, admission.id),
               opts
             )

    {owner, run} =
      if mode == :intent do
        assert {:ok, result} = PlanExecutor.advance(goal.id, opts)
        {Repo.get!(ReservationRecord, result.reservation_id), Repo.get!(RunRecord, result.run_id)}
      else
        {:ok, policy} = ReservationPolicy.new()

        attrs = %{
          id: Ecto.UUID.generate(),
          goal_id: goal.id,
          execution_id: Ecto.UUID.generate(),
          plan_task_id: "alpha",
          attempt: 1,
          run_id: Ecto.UUID.generate(),
          admission_event_id: admission.id
        }

        assert {:ok, owner} = Reservations.hold(attrs, policy, now: now)
        {owner, nil}
      end

    assert {:ok, _} = Shoestring.Harness.Projector.project(goal.id, clock: PlanHandoffClock)
    %{goal: goal, owner: owner, run: run, opts: opts}
  end
end
