defmodule Shoestring.Test.PlanExecutorHelpers do
  @moduledoc """
  Hermetic helpers for sequential plan-executor tests: approved-plan setup,
  grant-grade admission decisions, run terminals, and gate-runner injection.

  Everything is synthetic: fabricated base revisions, `human:` identities,
  fixed clocks, and an injected gate runner that never spawns an OS
  process. No provider CLI, no network.
  """

  import Ecto.Query
  import ExUnit.Assertions

  alias Shoestring.Cobbler.Plans
  alias Shoestring.Repo
  alias Shoestring.Test.Fixtures.FakeHelpers
  alias Shoestring.Test.PlanFixtures
  alias Shoestring.Trajectory

  @now ~U[2026-09-30 12:00:00.000000Z]

  @doc "Fixed deterministic timestamp for executor tests."
  @spec now() :: DateTime.t()
  def now, do: @now

  @doc "A two-task sequential chain plan (`alpha` then `beta`)."
  @spec chain_plan(map()) :: map()
  def chain_plan(overrides \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "goal" => PlanFixtures.goal(),
        "budget" => %{"max_total_attempts" => 6, "max_total_duration_seconds" => 7_200},
        "tasks" => [
          PlanFixtures.task("alpha", "Do the first thing", []),
          PlanFixtures.task("beta", "Do the second thing", ["alpha"])
        ]
      },
      overrides
    )
  end

  @doc "Two dependency-independent tasks that must still run sequentially."
  @spec independent_plan() :: map()
  def independent_plan do
    %{
      "version" => 1,
      "goal" => PlanFixtures.goal(),
      "budget" => %{"max_total_attempts" => 6, "max_total_duration_seconds" => 7_200},
      "tasks" => [
        PlanFixtures.task("north", "Do the north thing", []),
        PlanFixtures.task("south", "Do the south thing", [])
      ]
    }
  end

  @doc "Proposes and approves a plan revision; returns revision number and digest."
  @spec propose_and_approve!(Shoestring.Trajectory.Goal.t(), map()) :: %{
          revision_number: pos_integer(),
          digest: String.t()
        }
  def propose_and_approve!(goal, plan \\ nil) do
    plan = plan || chain_plan()
    plan_opts = [now: @now, publish_fun: fn _event -> :ok end]

    assert {:ok, %{revision: revision}} =
             Plans.propose(
               goal.id,
               PlanFixtures.propose_attrs(plan: plan),
               plan_opts
             )

    assert {:ok, _decision} =
             Plans.approve(
               goal.id,
               PlanFixtures.approve_attrs(revision.revision_number, revision.digest),
               plan_opts
             )

    %{revision_number: revision.revision_number, digest: revision.digest}
  end

  @doc """
  Appends a grant-grade admit decision for a goal: a projected capacity
  snapshot plus full proposed bounds (deadline, reserves, cadence), so the
  lease gate can build. Every call mints a fresh decision id.
  """
  @spec admit!(Shoestring.Trajectory.Goal.t()) :: Trajectory.TrajectoryEvent.t()
  def admit!(goal) do
    snapshot_id = Ecto.UUID.generate()
    FakeHelpers.append_capacity_snapshot(goal, snapshot_id)

    payload =
      Shoestring.Test.CobblerHelpers.admission_payload()
      |> Map.merge(%{
        "decision_id" => Ecto.UUID.generate(),
        "observation" => %{
          "snapshot_id" => snapshot_id,
          "confidence" => "high",
          "freshness" => "fresh"
        },
        "proposed_bounds" => %{
          "response_budget" => 10,
          "tool_budget" => 25,
          "deadline" => DateTime.to_iso8601(DateTime.add(@now, 300, :second)),
          "checkpoint_cadence" => 1,
          "reserves" => %{"response" => 1, "tool" => 1}
        }
      })

    Shoestring.Test.CobblerHelpers.append_admission_event!(goal.id, payload)
  end

  @doc "Appends a `run.completed` terminal for a dispatched run."
  @spec complete_run!(Shoestring.Trajectory.Goal.t(), Ecto.UUID.t()) :: :ok
  def complete_run!(goal, run_id) do
    {:ok, _event} =
      Trajectory.append(
        goal.id,
        %{
          "type" => "run.completed",
          "schema_version" => 1,
          "actor" => "test",
          "occurred_at" => @now,
          "payload" => %{"run_id" => run_id}
        },
        trusted: [run_id: run_id]
      )

    :ok
  end

  @doc "Gate-runner opts with an injected function: never spawns an OS process."
  @spec gate_opts(keyword()) :: keyword()
  def gate_opts(overrides \\ []) do
    exit_status = Keyword.get(overrides, :exit_status, 0)

    runner = fn _argv, _worktree, _timeout ->
      {:ok, %{exit_status: exit_status, output: "hermetic gate output", duration_ms: 7}}
    end

    [
      runner: runner,
      worktree_path: File.cwd!(),
      commit: PlanFixtures.base_revision()
    ]
  end

  @doc "Executor call opts carrying admission, gates, and deterministic time."
  @spec exec_opts(keyword()) :: keyword()
  def exec_opts(extra \\ []) do
    Keyword.merge(
      [now: @now, gate_runner_opts: gate_opts()],
      extra
    )
  end

  @doc "Counts run rows for a goal."
  @spec run_count(Ecto.UUID.t()) :: non_neg_integer()
  def run_count(goal_id) do
    Repo.aggregate(
      from(run in Shoestring.Harness.RunRecord, where: run.goal_id == ^goal_id),
      :count,
      :id
    )
  end
end
