defmodule Shoestring.Trajectory.PlanEventTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.Cobbler.{Plans, PlanContract, PlanProjection}
  alias Shoestring.Trajectory.{EventRegistry, Goal, TrajectoryEvent}
  import Shoestring.Test.PlanHelpers
  @moduledoc "Feature tests for strict canonical plan events and fail-closed replay."

  setup do
    owner = Ecto.UUID.generate()
    goal_id = Ecto.UUID.generate()
    assert {:ok, creation} = Plans.create_goal(owner, goal_id, "create", goal_contract())
    assert {:ok, proposal} = Plans.propose(owner, goal_id, "propose", nil, plan())

    %{
      owner: owner,
      goal_id: goal_id,
      goal: Repo.get!(Goal, goal_id),
      events: [creation.event, proposal.event],
      proposal: proposal
    }
  end

  test "registry rejects unknown nested fields on writes and historical reads", ctx do
    event = ctx.proposal.event
    bad = put_in(event.payload, ["request", "content", "goal", "acceptance", "shell"], "true")

    assert {:error, {:invalid_payload, _, 1, _}} =
             EventRegistry.validate_payload(event.type, 1, bad)

    assert {:error, {:invalid_payload, _, 1, _}} =
             EventRegistry.validate(Map.from_struct(%{event | payload: bad}))

    assert {:error, {:unknown_event_version, _, 2}} =
             EventRegistry.validate_payload(event.type, 2, event.payload)

    assert {:error, _} = EventRegistry.validate_payload(event.type, 1, %{"request" => self()})
  end

  test "bounded scanner rejects credential markers and preserves ordinary contract fields", ctx do
    event = ctx.proposal.event

    bad =
      put_in(
        event.payload,
        ["request", "content", "tasks", Access.at(0), "outcome"],
        "password: synthetic-fixture"
      )

    assert {:error, _} = EventRegistry.validate_payload(event.type, 1, bad)
    assert {:ok, valid} = EventRegistry.validate_payload(event.type, 1, event.payload)
    assert valid["request"]["content"]["goal"]["acceptance"] == acceptance()
    assert valid["request"]["content"]["tasks"] == plan()["tasks"]
  end

  test "replay checks ownership, sequence, request digest and proposal DAG", ctx do
    [created, event] = ctx.events

    for bad <- [
          %{event | goal_id: Ecto.UUID.generate()},
          %{event | actor: "model:fixture"},
          %{event | sequence: created.sequence},
          %{event | payload: Map.put(event.payload, "request_digest", String.duplicate("0", 64))}
        ] do
      assert {:error, {:invalid_plan_history, _, _}} =
               Plans.replay_events(ctx.goal, [created, bad])
    end

    bad_request =
      put_in(event.payload["request"], ["content", "tasks"], [
        task(task_a(), [task_b()]),
        task(task_b(), [task_a()])
      ])

    digest =
      PlanContract.digest(%{
        "type" => event.type,
        "owner_id" => ctx.owner,
        "request" => bad_request
      })

    bad = %{
      event
      | payload: %{event.payload | "request" => bad_request, "request_digest" => digest}
    }

    assert {:error, {:invalid_plan_history, _, {:invalid_payload, _, 1, _}}} =
             Plans.replay_events(ctx.goal, [created, bad])
  end

  test "canonical authority survives replacement of every derived plan field", ctx do
    revision = ctx.proposal.state["revisions"][ctx.proposal.event.id]

    assert {:ok, approval} =
             Plans.approve(ctx.owner, ctx.goal_id, "approve", revision["id"], revision["digest"])

    expected = approval.state
    assert {:ok, ^expected} = Plans.replay_events(ctx.goal, ctx.events ++ [approval.event])

    Repo.get!(PlanProjection, ctx.goal_id)
    |> change(state: %{"active_revision" => "forged"}, last_sequence: 999)
    |> Repo.update!()

    assert {:ok, ^expected} = Plans.read(ctx.owner, ctx.goal_id)
    assert {:ok, ^expected} = Plans.rebuild(ctx.owner, ctx.goal_id)
    assert Repo.get!(PlanProjection, ctx.goal_id).state == expected
    assert {:ok, replayed} = Shoestring.Trajectory.replay(ctx.goal_id)
    assert Enum.map(replayed, & &1.id) == Enum.map(ctx.events ++ [approval.event], & &1.id)
    assert Repo.aggregate(TrajectoryEvent, :count) == 3
  end

  test "canonical proposal writes reject cycles and aggregate budgets before persistence", ctx do
    event = ctx.proposal.event

    cyclic =
      put_in(event.payload, ["request", "content", "tasks"], [
        task(task_a(), [task_b()]),
        task(task_b(), [task_a()])
      ])

    over_budget =
      put_in(
        event.payload,
        ["request", "content", "goal", "budget", "max_total_response_tokens"],
        3999
      )

    for bad <- [cyclic, over_budget] do
      assert {:error, {:invalid_payload, _, 1, _}} =
               EventRegistry.validate_payload(event.type, 1, bad)

      assert {:error, _} =
               Shoestring.Trajectory.append(ctx.goal_id, %{
                 "type" => event.type,
                 "actor" => "human:" <> ctx.owner,
                 "schema_version" => 1,
                 "payload" => bad
               })
    end

    assert Repo.aggregate(TrajectoryEvent, :count) == 2
  end

  test "future plan versions/types and duplicate causal identities fail closed", ctx do
    [created, proposal] = ctx.events

    for changed <- [
          %{proposal | schema_version: 2},
          %{proposal | type: "cobbler.plan.future"},
          %{proposal | id: created.id},
          %{proposal | parent_event_id: created.id},
          %{proposal | idempotency_key: "different-key"}
        ] do
      assert {:error, {:invalid_plan_history, _, _}} =
               Plans.replay_events(ctx.goal, [created, changed])
    end
  end
end
