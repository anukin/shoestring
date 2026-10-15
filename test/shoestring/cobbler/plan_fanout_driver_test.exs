defmodule Shoestring.Cobbler.PlanFanoutDriverTest do
  @moduledoc "Production fan-out selection and completion, with Fake admission and local Git."
  use Shoestring.DataCase, async: false
  import Shoestring.Test.PlanFanoutHelpers

  alias Shoestring.Cobbler.{ExecutionControl, PlanExecutor, PlanFanoutDriver}
  alias Shoestring.Test.PlanExecutorHelpers
  alias Shoestring.Trajectory.{Goal, TrajectoryEvent}
  alias Shoestring.Worktrees

  @concurrent %{global_limit: 2, provider_account_limit: 2, goal_limit: 2, account_units: 2}

  defp unit(overrides \\ []) do
    fixture(Keyword.put(overrides, :reconciliation_opts, group_probe: fn _ -> :absent end))
  end

  defp step(c, extra \\ []) do
    opts =
      c.opts
      |> Keyword.drop([:fanout_enabled, :reservation_policy])
      |> Keyword.merge(plan_fanout: [enabled: true], reservation_policy: @concurrent)
      |> Keyword.merge(extra)

    PlanFanoutDriver.step(c.goal.id, opts)
  end

  defp commit_change!(c, child) do
    {:ok, tree} = Worktrees.get(child.run_id, c.opts)

    File.write!(
      Path.join(tree.path, "lib/#{child.plan_task_id}.ex"),
      "defmodule #{String.capitalize(child.plan_task_id)} do\n  def changed, do: true\nend\n"
    )

    git!(tree.path, ["add", "."])
    git!(tree.path, ["commit", "-m", "Change #{child.plan_task_id}"])
    tree
  end

  defp accept!(c, child) do
    complete_child!(c.goal, child.run_id)

    assert {:ok, %{disposition: :accepted}} =
             PlanExecutor.complete_task_run(c.goal.id, child.run_id, c.opts)
  end

  test "fan-out is off by default and never selected by plan content" do
    refute PlanFanoutDriver.enabled?()
    refute PlanFanoutDriver.enabled?([])
    assert PlanFanoutDriver.enabled?(enabled: true)
    assert Application.get_env(:shoestring, :plan_fanout) == [enabled: false]
  end

  test "an eligible independent plan dispatches concurrent children through the driver" do
    c = unit(independent_only: true)
    assert {:ok, %{disposition: :dispatched, dispatched: [north, south]}} = step(c)
    assert {north.plan_task_id, south.plan_task_id} == {"north", "south"}

    assert {:ok, %{dispatch_mode: :fanout_v1, active_children: [_, _]}} =
             PlanExecutor.status(c.goal.id, c.opts)

    # While children run, a step waits without admitting anything else.
    assert {:ok, %{disposition: :awaiting_task}} =
             step(c, admission_fun: fn _, _, _, _ -> flunk("duplicate admission") end)
  end

  test "default limits of one keep the ordinary sequential executor" do
    c = unit(independent_only: true)

    assert {:ok, %{disposition: :dispatched, plan_task_id: "north"}} =
             step(c,
               reservation_policy: %{},
               admission_event_id: admission!(c.goal).id,
               gate_runner_opts: PlanExecutorHelpers.gate_opts()
             )

    assert {:ok, %{dispatch_mode: :sequential, total_attempts: 1}} =
             PlanExecutor.status(c.goal.id, c.opts)
  end

  test "uncertain independence falls back to sequential execution" do
    c =
      unit(
        independent_only: true,
        transform_tasks: fn tasks ->
          Enum.map(tasks, &put_in(&1, ["hints", "files"], ["lib/north.ex"]))
        end
      )

    assert {:ok, %{plan_task_id: "north"}} =
             step(c, admission_event_id: admission!(c.goal).id)

    assert {:ok, %{dispatch_mode: :sequential, total_attempts: 1}} =
             PlanExecutor.status(c.goal.id, c.opts)

    assert Repo.exists?(
             from e in TrajectoryEvent,
               where: e.goal_id == ^c.goal.id and e.type == "cobbler.plan.independence.evaluated"
           )
  end

  test "a fan-out execution completes through global gates and completes the goal row" do
    c = unit(independent_only: true)
    assert {:ok, %{dispatched: [north, south]}} = step(c)
    accept!(c, north)
    assert {:ok, %{disposition: :awaiting_task}} = step(c)
    accept!(c, south)

    assert {:ok, %{disposition: :completed}} = step(c)
    assert {:ok, %{completed?: true}} = PlanExecutor.status(c.goal.id, c.opts)
    assert %Goal{status: "completed"} = Repo.get!(Goal, c.goal.id)
    assert {:ok, %{disposition: :completed}} = step(c)
  end

  test "committed sibling outputs require recorded human integration before completion" do
    c = unit(independent_only: true)
    assert {:ok, %{dispatched: [north, south]}} = step(c)
    branches = Enum.map([north, south], &commit_and_accept!(c, &1))

    assert {:ok, %{disposition: :blocked, reason: :integration_required}} = step(c)
    assert {:ok, %{completed?: false, integration: nil}} = PlanExecutor.status(c.goal.id, c.opts)
    # Nothing was merged into the user's repository on their behalf.
    assert git!(c.source, ["rev-parse", "HEAD"]) |> String.trim() == c.base

    integrated = merge!(c, branches)
    assert {:ok, event} = integrate(c, integrated)
    assert event.payload["accepted_commits"] == Enum.sort(Enum.map(branches, &elem(&1, 2)))
    assert {:ok, ^event} = integrate(c, integrated, event.payload["integration_id"])

    assert {:ok, %{disposition: :completed}} = step(c)
    assert {:ok, %{completed?: true}} = PlanExecutor.status(c.goal.id, c.opts)

    {:ok, verify} =
      Worktrees.get(
        PlanExecutor.integration_workspace_id(c.execution.execution_id, integrated),
        c.opts
      )

    assert verify.base_commit == integrated and verify.path != c.source
    assert git!(c.source, ["status", "--porcelain"]) == ""
  end

  test "a dependent unlocks only after both acceptances and continues from the integration" do
    c = unit()
    assert {:ok, %{dispatched: [north, south]}} = step(c)
    north_branch = commit_and_accept!(c, north)
    assert {:ok, %{disposition: :awaiting_task}} = step(c)
    south_branch = commit_and_accept!(c, south)

    assert {:ok, %{disposition: :blocked, reason: :integration_required, blocked: blocked}} =
             step(c)

    assert [%{plan_task_id: "join", reason: :fanout_inputs_require_integration}] = blocked
    integrated = merge!(c, [north_branch, south_branch])

    # A commit that omits an accepted result is refused.
    assert {:error, :integration_commit_not_verified} = integrate(c, c.base)
    assert {:ok, _} = integrate(c, integrated)

    assert {:ok, %{disposition: :dispatched, plan_task_id: "join"} = join} =
             step(c, admission_event_id: admission!(c.goal).id)

    {:ok, tree} = Worktrees.get(join.run_id, c.opts)
    assert tree.base_commit == integrated
    accept!(c, join)
    assert {:ok, %{disposition: :completed}} = step(c)

    assert {:ok, %{completed?: true, accepted: ["join", "north", "south"]}} =
             PlanExecutor.status(c.goal.id, c.opts)
  end

  test "integration needs a human, a current execution and a full commit" do
    c = unit(independent_only: true)
    assert {:ok, %{dispatched: [north, _]}} = step(c)
    commit_and_accept!(c, north)

    assert {:error, :invalid_integration} = integrate(c, "abc")

    assert {:error, :invalid_integration} =
             ExecutionControl.integrate(c.goal.id, %{
               execution_id: c.execution.execution_id,
               commit: c.base,
               reason: "Merged.",
               command_id: Ecto.UUID.generate(),
               requested_by: "cobbler"
             })

    assert {:error, :integration_mismatch} =
             ExecutionControl.integrate(c.goal.id, %{
               execution_id: Ecto.UUID.generate(),
               commit: c.base,
               reason: "Merged.",
               command_id: Ecto.UUID.generate(),
               requested_by: "human:operator"
             })
  end

  defp commit_and_accept!(c, child) do
    tree = commit_change!(c, child)
    accept!(c, child)
    commit = git!(tree.path, ["rev-parse", "HEAD"]) |> String.trim()
    {tree.repo_path, tree.branch, commit}
  end

  # A human merges each retained branch in their own repository.
  defp merge!(c, branches) do
    for {path, branch, _commit} <- branches do
      git!(c.source, ["fetch", path, branch])
      git!(c.source, ["merge", "--no-ff", "--no-edit", "FETCH_HEAD"])
    end

    git!(c.source, ["rev-parse", "HEAD"]) |> String.trim()
  end

  defp integrate(c, commit, command_id \\ Ecto.UUID.generate()) do
    ExecutionControl.integrate(c.goal.id, %{
      execution_id: c.execution.execution_id,
      commit: commit,
      reason: "Merged the accepted branches.",
      command_id: command_id,
      requested_by: "human:operator"
    })
  end

  test "cancelled children block the step for an operator instead of polling forever" do
    c = unit(independent_only: true)
    assert {:ok, %{dispatched: [north, south]}} = step(c)

    for child <- [north, south] do
      assert {:ok, request} =
               Shoestring.Cobbler.ExecutionControl.cancel(c.goal.id, %{
                 execution_id: c.execution.execution_id,
                 run_id: child.run_id,
                 reason: "Stop.",
                 command_id: Ecto.UUID.generate(),
                 requested_by: "human:operator"
               })

      assert {:ok, _} =
               Shoestring.Cobbler.PlanCancellation.perform(
                 c.goal.id,
                 request.cancellation_id,
                 Keyword.put(c.opts, :elf_lookup, fn _ -> nil end)
               )
    end

    assert {:ok, %{disposition: :blocked, reason: :operator_continuation_required}} = step(c)
  end

  describe "production worker routing" do
    setup do
      previous = {
        Application.get_env(:shoestring, :plan_fanout),
        Application.get_env(:shoestring, :plan_reservation_policy)
      }

      on_exit(fn ->
        Application.put_env(:shoestring, :plan_fanout, elem(previous, 0))
        Application.put_env(:shoestring, :plan_reservation_policy, elem(previous, 1))
      end)
    end

    test "enabled configuration routes the execution worker through the fan-out driver" do
      c = unit(independent_only: true)
      Application.put_env(:shoestring, :plan_fanout, enabled: true)
      Application.put_env(:shoestring, :plan_reservation_policy, @concurrent)
      opts = Keyword.drop(c.opts, [:fanout_enabled, :reservation_policy])

      assert {:ok, %{disposition: :dispatched, dispatched: [_, _]}} =
               Shoestring.Cobbler.PlanExecutionWorker.drive(c.goal.id, opts)

      assert {:ok, %{dispatch_mode: :fanout_v1}} = PlanExecutor.status(c.goal.id, c.opts)
    end

    test "default configuration keeps the sequential executor" do
      c = unit(independent_only: true)
      Application.put_env(:shoestring, :plan_reservation_policy, @concurrent)

      opts =
        c.opts
        |> Keyword.drop([:fanout_enabled, :reservation_policy])
        |> Keyword.put(:admission_event_id, admission!(c.goal).id)

      assert {:ok, %{disposition: :dispatched, plan_task_id: "north"}} =
               Shoestring.Cobbler.PlanExecutionWorker.drive(c.goal.id, opts)

      assert {:ok, %{dispatch_mode: :sequential, total_attempts: 1}} =
               PlanExecutor.status(c.goal.id, c.opts)
    end
  end
end
