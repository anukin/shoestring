defmodule Shoestring.Cobbler.PlanPartialFailureTest do
  @moduledoc """
  Hermetic partial-failure policy for fan-out children. Only unstarted intent
  is cancelled here; live process-group cancellation runs in the isolated-node
  integration suite, never against a synthetic process id.
  """
  use Shoestring.DataCase, async: false
  import Shoestring.Test.PlanFanoutHelpers

  alias Shoestring.Cobbler.{
    ExecutionControl,
    PlanCancellation,
    PlanExecutor,
    PlanFanout,
    Reservations
  }

  alias Shoestring.Harness.{Projector, RunRecord}
  alias Shoestring.Test.{PlanExecutorHelpers, PlanHandoffClock}
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.{EventRegistry, Goal, TrajectoryEvent}
  alias Shoestring.Worktrees

  defp unit(overrides) do
    fixture(Keyword.put(overrides, :reconciliation_opts, group_probe: fn _ -> :absent end))
  end

  defp append!(goal, run_id, type, payload \\ %{}) do
    assert {:ok, _} =
             Trajectory.append(
               goal.id,
               %{
                 "type" => type,
                 "schema_version" => 1,
                 "actor" => "test",
                 "occurred_at" => PlanExecutorHelpers.now(),
                 "payload" => Map.put(payload, "run_id", run_id)
               },
               trusted: [run_id: run_id]
             )
  end

  defp start!(goal, run_id) do
    append!(goal, run_id, "run.starting")
    append!(goal, run_id, "run.running", %{"process_id" => "pgid:424242"})
  end

  defp fail!(c, child, category \\ "task_failed") do
    start!(c.goal, child.run_id)

    append!(c.goal, child.run_id, "run.failed", %{
      "error_category" => category,
      "error_code" => "x"
    })

    PlanExecutor.complete_task_run(c.goal.id, child.run_id, c.opts)
  end

  defp checkpoint!(goal, run_id, next_action) do
    id = Ecto.UUID.generate()

    {:ok, _} =
      Trajectory.append(
        goal.id,
        %{
          "type" => "checkpoint.created",
          "schema_version" => 1,
          "actor" => "test",
          "occurred_at" => PlanExecutorHelpers.now(),
          "payload" => %{
            "checkpoint_id" => id,
            "run_id" => run_id,
            "contract_version" => 1,
            "acceptance_contract" => %{"criteria" => ["format passes"]},
            "repository_state" => %{"revision" => "abc123", "dirty" => false},
            "evidence" => %{"items" => ["format checked"]},
            "decisions" => %{"items" => ["kept the public API"]},
            "unresolved_issues" => %{"items" => []},
            "next_action" => next_action,
            "stop_reason" => "task_failed",
            "artifact_ids" => %{"items" => []},
            "extensions" => %{}
          }
        },
        trusted: [run_id: run_id]
      )

    assert {:ok, _} = Projector.project(goal.id, clock: PlanHandoffClock)
    id
  end

  defp child(c, run_id) do
    {:ok, status} = PlanExecutor.status(c.goal.id, c.opts)
    Enum.find(status.children, &(&1.run_id == run_id))
  end

  defp cancel(c, attrs) do
    ExecutionControl.cancel(
      c.goal.id,
      Map.merge(
        %{
          execution_id: c.execution.execution_id,
          reason: "Stop this work.",
          command_id: Ecto.UUID.generate(),
          requested_by: "human:operator"
        },
        attrs
      )
    )
  end

  defp perform!(c, id) do
    PlanCancellation.perform(
      c.goal.id,
      id,
      Keyword.merge(c.opts, elf_lookup: fn _ -> nil end)
    )
  end

  test "a failed child is replaced through admission with only its own checkpoint" do
    c = unit(independent_only: true)
    parent = self()

    opts =
      Keyword.put(c.opts, :admission_fun, fn goal_id, _, task, attempt ->
        send(parent, {:admitted, task["id"], attempt})
        {:ok, admission!(%{c.goal | id: goal_id}).id}
      end)

    assert {:ok, %{dispatched: [north, south]}} = PlanFanout.dispatch_ready(c.goal.id, opts)
    assert_received {:admitted, "north", 1}
    assert_received {:admitted, "south", 1}
    own = checkpoint!(c.goal, north.run_id, "retry the formatter on lib/north.ex")
    _sibling = checkpoint!(c.goal, south.run_id, "SIBLING-ONLY next action")

    assert {:ok, %{disposition: :gate_failed, retry_state: "retry"}} = fail!(c, north)
    assert %{stop_class: :task_failure, resolved?: true} = child(c, north.run_id)

    assert {:ok, %{dispatched: [replacement], blocked: []}} =
             PlanFanout.dispatch_ready(c.goal.id, opts)

    assert_received {:admitted, "north", 2}
    assert replacement.plan_task_id == "north" and replacement.attempt == 2
    run = Repo.get!(RunRecord, replacement.run_id)
    assert run.prompt =~ "Replacement context (own task only)"
    assert run.prompt =~ "Previous attempt 1 failed at"
    assert run.prompt =~ "Continue from checkpoint #{own}"
    refute run.prompt =~ "SIBLING-ONLY"
    assert run.extensions["shoestring.plan:binding"]["attempt"] == 2

    {:ok, first_tree} = Worktrees.get(north.run_id, c.opts)
    {:ok, second_tree} = Worktrees.get(replacement.run_id, c.opts)
    assert first_tree.path != second_tree.path
    assert second_tree.base_commit == c.base

    # The replacement converges on replay and is never admitted twice.
    assert {:ok, %{dispatched: []}} = PlanFanout.dispatch_ready(c.goal.id, opts)
    refute_received {:admitted, _, _}
  end

  test "adapter failure is classified separately and exhausted attempts escalate" do
    c = unit(independent_only: true)
    assert {:ok, %{dispatched: [north, _south]}} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
    assert {:ok, %{retry_state: "retry"}} = fail!(c, north, "transport")
    assert %{stop_class: :adapter_failure} = child(c, north.run_id)

    assert {:ok, %{dispatched: [second]}} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
    assert second.attempt == 2
    assert {:ok, %{retry_state: "escalate"}} = fail!(c, second)
    assert {:ok, %{dispatched: []}} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
    assert {:ok, %{needs_user?: true, total_attempts: 3}} = PlanExecutor.status(c.goal.id, c.opts)
  end

  test "quota sleep, interruption and cancellation are classified and never replaced" do
    c = unit(independent_only: true)
    assert {:ok, %{dispatched: [north, south]}} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
    start!(c.goal, north.run_id)
    append!(c.goal, north.run_id, "run.suspended")
    start!(c.goal, south.run_id)
    append!(c.goal, south.run_id, "run.interrupted")

    assert %{stop_class: :quota_sleep, resolved?: false} = child(c, north.run_id)
    assert %{stop_class: :interrupted, resolved?: false} = child(c, south.run_id)

    assert {:ok, %{dispatched: []}} =
             PlanFanout.dispatch_ready(
               c.goal.id,
               Keyword.put(c.opts, :admission_fun, fn _, _, _, _ -> flunk("replaced") end)
             )
  end

  test "child cancellation fences one unstarted child and leaves its sibling held" do
    c = unit(independent_only: true)
    assert {:ok, %{dispatched: [north, south]}} = PlanFanout.dispatch_ready(c.goal.id, c.opts)

    assert {:ok, %{scope: "child", job_id: job_id, completed?: false} = request} =
             cancel(c, %{run_id: north.run_id})

    assert %Oban.Job{queue: "plan_cancellation"} = Repo.get!(Oban.Job, job_id)

    assert {:ok, %{outcome: :completed, outcomes: [%{"outcome" => "fenced_unstarted"}]}} =
             perform!(c, request.cancellation_id)

    assert Enum.map(Reservations.outstanding(), & &1.run_id) == [south.run_id]
    assert Repo.get!(RunRecord, north.run_id).status == "cancelled"
    assert Repo.get!(RunRecord, south.run_id).status == "requested"

    assert {:ok, status} = PlanExecutor.status(c.goal.id, c.opts)
    refute status.cancelled?
    assert %{stop_class: :cancelled} = Enum.find(status.children, &(&1.run_id == north.run_id))
    assert [%{scope: "child", completed?: true}] = status.cancellations
    assert Repo.get!(Goal, c.goal.id).status == "active"
    assert {:ok, %{dispatched: []}} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
    assert {:ok, %{outcome: :replayed}} = perform!(c, request.cancellation_id)
  end

  test "goal cancellation stops every unresolved child and fences further work" do
    c = unit(independent_only: true)
    assert {:ok, %{dispatched: [_north, _south]}} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
    attrs = %{command_id: Ecto.UUID.generate()}
    assert Repo.get!(Goal, c.goal.id).status == "active"
    assert {:ok, %{scope: "goal"} = request} = cancel(c, attrs)
    # The generic goal row follows the canonical cancellation; the baseline
    # left it `active`.
    assert Repo.get!(Goal, c.goal.id).status == "cancelled"
    assert {:ok, %{cancellation_id: id}} = cancel(c, attrs)
    assert id == request.cancellation_id
    assert {:error, :cancellation_conflict} = cancel(c, Map.put(attrs, :reason, "Different."))

    assert {:ok, %{outcomes: outcomes}} = perform!(c, request.cancellation_id)
    assert Enum.map(outcomes, & &1["outcome"]) == ["fenced_unstarted", "fenced_unstarted"]
    assert Reservations.outstanding() == []

    assert {:ok, %{cancelled?: true}} = PlanExecutor.status(c.goal.id, c.opts)
    assert {:error, :execution_cancelled} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
    assert {:error, :execution_cancelled} = PlanExecutor.advance(c.goal.id, c.opts)

    # A cancelled execution cannot authorize a plan continuation either.
    run = Repo.get!(RunRecord, hd(outcomes)["run_id"])

    assert {:error, :execution_cancelled} =
             Shoestring.Cobbler.PlanBudget.authorize_continuation(Repo, run)
  end

  test "requests need a human identity, a current execution and an active child target" do
    c = unit(independent_only: true)
    assert {:ok, %{dispatched: [north, _]}} = PlanFanout.dispatch_ready(c.goal.id, c.opts)
    assert {:error, :invalid_cancellation} = cancel(c, %{requested_by: "cobbler"})
    assert {:error, :invalid_cancellation} = cancel(c, %{reason: " "})
    assert {:error, :cancellation_mismatch} = cancel(c, %{execution_id: Ecto.UUID.generate()})

    assert {:error, :cancellation_target_not_active} =
             cancel(c, %{run_id: Ecto.UUID.generate()})

    assert {:ok, _} = cancel(c, %{run_id: north.run_id})

    refute Repo.exists?(
             from e in TrajectoryEvent, where: e.type == "cobbler.plan.cancellation.completed"
           )
  end

  test "the registry binds cancellation scope and bounded outcomes" do
    base = %{
      "cancellation_id" => Ecto.UUID.generate(),
      "execution_id" => Ecto.UUID.generate(),
      "revision_number" => 1,
      "plan_digest" => String.duplicate("a", 64),
      "scope" => "goal",
      "requested_by" => "human:operator",
      "reason" => "Stop."
    }

    requested = &EventRegistry.validate_payload("cobbler.plan.cancellation.requested", 1, &1)
    assert {:ok, _} = requested.(base)

    assert {:ok, _} =
             requested.(%{base | "scope" => "child"} |> Map.put("run_id", Ecto.UUID.generate()))

    assert {:error, _} = requested.(%{base | "scope" => "child"})
    assert {:error, _} = requested.(Map.put(base, "run_id", Ecto.UUID.generate()))
    assert {:error, _} = requested.(%{base | "requested_by" => "cobbler"})

    completed = &EventRegistry.validate_payload("cobbler.plan.cancellation.completed", 1, &1)
    outcome = %{"run_id" => Ecto.UUID.generate(), "outcome" => "cancelled"}

    ok = %{
      "cancellation_id" => base["cancellation_id"],
      "execution_id" => base["execution_id"],
      "outcomes_complete" => true
    }

    assert {:ok, _} = completed.(Map.put(ok, "outcomes", [outcome]))

    assert {:error, _} =
             completed.(Map.put(ok, "outcomes", [%{outcome | "outcome" => "retained"}]))

    assert {:error, _} = completed.(Map.put(ok, "outcomes", List.duplicate(outcome, 65)))
  end
end
