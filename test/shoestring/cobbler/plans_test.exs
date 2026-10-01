defmodule Shoestring.Cobbler.PlansTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.Cobbler
  alias Shoestring.Cobbler.{PlanContract, PlanProjection}
  alias Shoestring.Trajectory.{Goal, TrajectoryEvent, Projector}
  import Shoestring.Test.PlanHelpers
  @moduledoc "Feature tests for immutable human plans and exact decisions."

  setup do
    owner = Ecto.UUID.generate()
    goal = Ecto.UUID.generate()
    assert {:ok, created} = Cobbler.create_plan_goal(owner, goal, "create", goal_contract())
    assert created.state["contract"] == goal_contract()
    %{owner: owner, goal: goal}
  end

  defp propose(%{owner: owner, goal: goal}, request \\ "propose", base \\ nil, content \\ plan()) do
    assert {:ok, result} = Cobbler.propose_plan(owner, goal, request, base, content)
    revision = result.state["revisions"][result.event.id]
    {result, revision}
  end

  test "proposal is inert; approval binds revision content and attributed decision", ctx do
    {proposal, revision} = propose(ctx)
    assert revision["status"] == "proposed"
    assert revision["digest"] == PlanContract.digest(plan())
    assert {:ok, nil} = Cobbler.active_plan_authority(ctx.owner, ctx.goal)

    assert {:error, :digest_mismatch} =
             Cobbler.approve_plan(
               ctx.owner,
               ctx.goal,
               "wrong",
               revision["id"],
               String.duplicate("0", 64)
             )

    assert {:ok, approved} =
             Cobbler.approve_plan(
               ctx.owner,
               ctx.goal,
               "approve",
               revision["id"],
               revision["digest"]
             )

    assert {:ok, authority} = Cobbler.active_plan_authority(ctx.owner, ctx.goal)
    assert authority["id"] == revision["id"]
    assert authority["content"] == revision["content"]
    assert authority["decision"]["actor"] == "human:" <> ctx.owner
    assert authority["decision"]["event_id"] == approved.event.id
    assert Repo.aggregate(TrajectoryEvent, :count) == 3
    assert Repo.aggregate(Shoestring.Trajectory.Task, :count) == 0
    assert Repo.aggregate(Shoestring.Harness.RunRecord, :count) == 0
    assert proposal.event.payload["request"]["content"] == plan()
  end

  test "repeated creation/proposal/approval returns exact event; conflicting request rolls back",
       ctx do
    assert {:ok, %{repeated?: true}} =
             Cobbler.create_plan_goal(ctx.owner, ctx.goal, "create", goal_contract())

    {proposal, revision} = propose(ctx)
    assert {:ok, repeat} = Cobbler.propose_plan(ctx.owner, ctx.goal, "propose", nil, plan())
    assert repeat.repeated?
    assert repeat.event.id == proposal.event.id
    changed = put_in(plan(), ["tasks", Access.at(0), "outcome"], "Changed outcome")

    assert {:error, :idempotency_conflict} =
             Cobbler.propose_plan(ctx.owner, ctx.goal, "propose", nil, changed)

    assert {:ok, approved} =
             Cobbler.approve_plan(
               ctx.owner,
               ctx.goal,
               "approve",
               revision["id"],
               revision["digest"]
             )

    assert {:ok, repeated} =
             Cobbler.approve_plan(
               ctx.owner,
               ctx.goal,
               "approve",
               revision["id"],
               revision["digest"]
             )

    assert repeated.event.id == approved.event.id
    assert repeated.repeated?
    assert Repo.aggregate(TrajectoryEvent, :count) == 3

    assert {:error, :idempotency_conflict} =
             Cobbler.reject_plan(
               ctx.owner,
               ctx.goal,
               "approve",
               revision["id"],
               revision["digest"],
               "No"
             )
  end

  test "new revisions preserve immutable contents; latest approval supersedes exact old authority",
       ctx do
    {_, first} = propose(ctx)

    assert {:ok, _} =
             Cobbler.approve_plan(ctx.owner, ctx.goal, "approve", first["id"], first["digest"])

    changed =
      plan()
      |> put_in(["goal", "non_goals"], ["No UI"])
      |> put_in(["tasks", Access.at(0), "outcome"], "A different bounded outcome")

    {_, second} = propose(ctx, "edit", first["id"], changed)
    assert {:ok, active} = Cobbler.active_plan_authority(ctx.owner, ctx.goal)
    assert active["id"] == first["id"]

    assert {:error, :stale_revision} =
             Cobbler.approve_plan(ctx.owner, ctx.goal, "stale", first["id"], first["digest"])

    assert {:ok, _} =
             Cobbler.approve_plan(
               ctx.owner,
               ctx.goal,
               "approve-edit",
               second["id"],
               second["digest"]
             )

    assert {:ok, old} = Cobbler.plan_revision(ctx.owner, ctx.goal, first["id"])
    assert old["content"] == plan()
    assert old["digest"] == first["digest"]
    assert old["status"] == "superseded"
    assert old["decision"]["status"] == "approved"
    assert {:ok, active} = Cobbler.active_plan_authority(ctx.owner, ctx.goal)
    assert active["id"] == second["id"]

    assert {:ok, repeat} =
             Cobbler.approve_plan(ctx.owner, ctx.goal, "approve", first["id"], first["digest"])

    assert repeat.repeated?
    assert repeat.state["active_revision"] == second["id"]
  end

  test "bounded rejection preserves active authority and cannot later approve the rejected revision",
       ctx do
    {_, first} = propose(ctx)

    assert {:ok, _} =
             Cobbler.approve_plan(ctx.owner, ctx.goal, "approve", first["id"], first["digest"])

    {_, second} = propose(ctx, "edit", first["id"])

    for reason <- [nil, " ", String.duplicate("x", 2001)] do
      assert {:error, _} =
               Cobbler.reject_plan(
                 ctx.owner,
                 ctx.goal,
                 "reject",
                 second["id"],
                 second["digest"],
                 reason
               )
    end

    assert {:error, :digest_mismatch} =
             Cobbler.reject_plan(
               ctx.owner,
               ctx.goal,
               "bad-digest",
               second["id"],
               String.duplicate("0", 64),
               "No"
             )

    assert {:ok, rejection} =
             Cobbler.reject_plan(
               ctx.owner,
               ctx.goal,
               "reject",
               second["id"],
               second["digest"],
               "Too broad"
             )

    assert rejection.state["revisions"][second["id"]]["decision"]["reason"] == "Too broad"

    assert {:ok, %{repeated?: true}} =
             Cobbler.reject_plan(
               ctx.owner,
               ctx.goal,
               "reject",
               second["id"],
               second["digest"],
               "Too broad"
             )

    assert {:error, :decision_conflict} =
             Cobbler.approve_plan(ctx.owner, ctx.goal, "late", second["id"], second["digest"])

    assert {:ok, active} = Cobbler.active_plan_authority(ctx.owner, ctx.goal)
    assert active["id"] == first["id"]
  end

  test "ownership and cross-goal revision references fail without writes", ctx do
    {_, revision} = propose(ctx)
    other = Ecto.UUID.generate()
    assert {:ok, _} = Cobbler.create_plan_goal(ctx.owner, other, "create", goal_contract())
    before = Repo.aggregate(TrajectoryEvent, :count)

    for owner <- [Ecto.UUID.generate(), nil] do
      assert {:error, _} = Cobbler.read_plan(owner, ctx.goal)
      assert {:error, _} = Cobbler.propose_plan(owner, ctx.goal, "edit", revision["id"], plan())

      assert {:error, _} =
               Cobbler.approve_plan(
                 owner,
                 ctx.goal,
                 "approve",
                 revision["id"],
                 revision["digest"]
               )

      assert {:error, _} =
               Cobbler.reject_plan(
                 owner,
                 ctx.goal,
                 "reject",
                 revision["id"],
                 revision["digest"],
                 "No"
               )

      assert {:error, _} = Cobbler.rebuild_plans(owner, ctx.goal)
    end

    assert {:error, :revision_not_found} =
             Cobbler.approve_plan(ctx.owner, other, "approve", revision["id"], revision["digest"])

    assert {:error, :revision_not_found} =
             Cobbler.reject_plan(
               ctx.owner,
               other,
               "reject",
               revision["id"],
               revision["digest"],
               "No"
             )

    assert {:error, _} = Cobbler.propose_plan(ctx.owner, other, "edit", revision["id"], plan())
    assert Repo.aggregate(TrajectoryEvent, :count) == before
  end

  test "invalid graph and stale base cause no canonical or projection writes", ctx do
    assert {:ok, before} = Cobbler.read_plan(ctx.owner, ctx.goal)
    invalid = Map.put(plan(), "tasks", [task(task_a(), [task_b()]), task(task_b(), [task_a()])])

    assert {:error, [%{code: :cycle}]} =
             Cobbler.propose_plan(ctx.owner, ctx.goal, "cycle", nil, invalid)

    assert {:error, _} =
             Cobbler.propose_plan(ctx.owner, ctx.goal, "stale", Ecto.UUID.generate(), plan())

    assert Repo.aggregate(TrajectoryEvent, :count) == 1
    assert Repo.get!(PlanProjection, ctx.goal).state == before
    assert {:ok, ^before} = Cobbler.read_plan(ctx.owner, ctx.goal)
  end

  test "revision count and initial budget/repository caps cannot be reset", ctx do
    {_, first} = propose(ctx)

    for changed <- [
          put_in(plan(), ["goal", "budget", "max_revisions"], 11),
          put_in(plan(), ["goal", "repository", "base_revision"], String.duplicate("b", 40))
        ] do
      assert {:error, :goal_identity_or_budget_changed} =
               Cobbler.propose_plan(ctx.owner, ctx.goal, "edit", first["id"], changed)
    end

    Enum.reduce(2..10, first["id"], fn n, base ->
      {_, revision} = propose(ctx, "edit-#{n}", base)
      revision["id"]
    end)

    assert {:ok, state} = Cobbler.read_plan(ctx.owner, ctx.goal)

    assert {:error, :stale_revision_or_revision_budget} =
             Cobbler.propose_plan(
               ctx.owner,
               ctx.goal,
               "eleventh",
               state["latest_revision"],
               plan()
             )

    assert map_size(state["revisions"]) == 10
  end

  test "ever-approved stable identities cannot disappear from later revisions", ctx do
    {_, first} = propose(ctx)

    assert {:ok, _} =
             Cobbler.approve_plan(ctx.owner, ctx.goal, "approve", first["id"], first["digest"])

    removed = Map.put(plan(), "tasks", [task(task_a())])

    assert {:error, :approved_task_identity_removed} =
             Cobbler.propose_plan(ctx.owner, ctx.goal, "remove", first["id"], removed)

    assert {:ok, old} = Cobbler.plan_revision(ctx.owner, ctx.goal, first["id"])
    assert old["content"] == first["content"]
  end

  test "rebuild replaces corrupt projections, reproducing content, decisions, active authority",
       ctx do
    {_, first} = propose(ctx)

    assert {:ok, _} =
             Cobbler.approve_plan(ctx.owner, ctx.goal, "approve", first["id"], first["digest"])

    {_, second} = propose(ctx, "edit", first["id"])

    assert {:ok, _} =
             Cobbler.reject_plan(
               ctx.owner,
               ctx.goal,
               "reject",
               second["id"],
               second["digest"],
               "No"
             )

    assert {:ok, expected} = Cobbler.read_plan(ctx.owner, ctx.goal)
    Repo.get!(PlanProjection, ctx.goal) |> change(state: %{}, last_sequence: 0) |> Repo.update!()
    assert {:ok, ^expected} = Cobbler.read_plan(ctx.owner, ctx.goal)
    assert {:ok, ^expected} = Cobbler.rebuild_plans(ctx.owner, ctx.goal)
    assert Repo.get!(PlanProjection, ctx.goal).state == expected
    assert {:ok, ^expected} = Cobbler.rebuild_plans(ctx.owner, ctx.goal)
    assert {:ok, _} = Projector.rebuild(ctx.goal)
    assert {:ok, ^expected} = Cobbler.read_plan(ctx.owner, ctx.goal)
    assert Repo.get!(Goal, ctx.goal).owner_id == ctx.owner
  end

  test "projection failure rolls back goal identity and canonical events together", ctx do
    goal = Ecto.UUID.generate()

    assert {:error, :projection_failed} =
             Cobbler.create_plan_goal(ctx.owner, goal, "create", goal_contract(),
               repo: Shoestring.Test.PlanFaultRepo
             )

    assert Repo.get(Goal, goal) == nil
    assert Repo.aggregate(TrajectoryEvent, :count) == 1
    assert Repo.get(PlanProjection, goal) == nil
  end

  test "terminal goal cannot acquire new plan authority, but repeats and replay retain history",
       ctx do
    {_, revision} = propose(ctx)

    assert {:ok, _} =
             Cobbler.approve_plan(
               ctx.owner,
               ctx.goal,
               "approve",
               revision["id"],
               revision["digest"]
             )

    Repo.get!(Goal, ctx.goal) |> change(status: "completed") |> Repo.update!()

    assert {:error, :goal_not_active} =
             Cobbler.propose_plan(ctx.owner, ctx.goal, "edit", revision["id"], plan())

    assert {:ok, %{repeated?: true}} =
             Cobbler.approve_plan(
               ctx.owner,
               ctx.goal,
               "approve",
               revision["id"],
               revision["digest"]
             )

    assert {:ok, active} = Cobbler.active_plan_authority(ctx.owner, ctx.goal)
    assert active["id"] == revision["id"]
    assert Repo.aggregate(TrajectoryEvent, :count) == 3
  end

  test "supersession leaves existing running work and completed task history untouched", ctx do
    tasks =
      for {id, status} <- [{task_a(), "completed"}, {task_b(), "in_progress"}] do
        %Shoestring.Trajectory.Task{id: id, goal_id: ctx.goal}
        |> Shoestring.Trajectory.Task.changeset(%{title: "Existing task", status: status})
        |> Repo.insert!()
      end

    run =
      Repo.insert!(%Shoestring.Harness.RunRecord{
        id: Ecto.UUID.generate(),
        goal_id: ctx.goal,
        task_id: task_b(),
        dispatch_id: Ecto.UUID.generate(),
        provider_id: "fake",
        workspace_ref: "workspace:fixture",
        request_version: 1,
        prompt: "Bounded fixture",
        continuation: %{},
        policy: %{},
        requested_capabilities: %{},
        extensions: %{},
        status: "running"
      })

    {_, first} = propose(ctx)

    assert {:ok, _} =
             Cobbler.approve_plan(ctx.owner, ctx.goal, "approve", first["id"], first["digest"])

    {_, second} = propose(ctx, "edit", first["id"])

    assert {:ok, _} =
             Cobbler.approve_plan(
               ctx.owner,
               ctx.goal,
               "approve-edit",
               second["id"],
               second["digest"]
             )

    assert Repo.get!(Shoestring.Harness.RunRecord, run.id) == run
    for task <- tasks, do: assert(Repo.get!(Shoestring.Trajectory.Task, task.id) == task)
    assert Repo.aggregate(Shoestring.Trajectory.Task, :count) == 2
    assert {:ok, _} = Cobbler.rebuild_plans(ctx.owner, ctx.goal)
    assert Repo.get!(Shoestring.Harness.RunRecord, run.id) == run
    for task <- tasks, do: assert(Repo.get!(Shoestring.Trajectory.Task, task.id) == task)
  end
end
