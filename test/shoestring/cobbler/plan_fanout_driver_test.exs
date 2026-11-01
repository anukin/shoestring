defmodule Shoestring.Cobbler.PlanFanoutDriverTest do
  @moduledoc "Production fan-out selection and completion, with Fake admission and local Git."
  use Shoestring.DataCase, async: false
  import Shoestring.Test.PlanFanoutHelpers

  import Ecto.Query
  alias Shoestring.Cobbler.{ExecutionControl, PlanExecutor, PlanFanoutDriver, PlanMerge}
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

  defp commit_change!(c, child, file \\ nil) do
    {:ok, tree} = Worktrees.get(child.run_id, c.opts)

    File.write!(
      Path.join(tree.path, file || "lib/#{child.plan_task_id}.ex"),
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

  test "Shoestring merges accepted sibling commits in its own worktree; global gates run there" do
    c = unit(independent_only: true)
    assert {:ok, %{dispatched: [north, south]}} = step(c)
    branches = Enum.map([north, south], &commit_and_accept!(c, &1))

    assert {:ok, %{disposition: :completed, commit: integrated}} = step(c)

    assert {:ok, %{completed?: true, integration: integration}} =
             PlanExecutor.status(c.goal.id, c.opts)

    assert integration.commit == integrated and integration.by == "shoestring"

    # Merged in plan order on the approved base, in Shoestring's worktree.
    {:ok, merge} =
      Worktrees.get(PlanExecutor.merge_workspace_id(c.execution.execution_id, c.base), c.opts)

    assert integration.source == merge.path and merge.path != c.source
    assert git!(merge.path, ["rev-parse", "HEAD"]) |> String.trim() == integrated

    assert git!(merge.path, ["log", "--format=%s", "--first-parent", "#{c.base}..HEAD"])
           |> String.split("\n", trim: true) == [
             "Merge south: Implement south",
             "Merge north: Implement north"
           ]

    for {_, _, commit} <- branches,
        do: git!(merge.path, ["merge-base", "--is-ancestor", commit, "HEAD"])

    event =
      Repo.get_by!(TrajectoryEvent, goal_id: c.goal.id, type: "cobbler.plan.integration.recorded")

    assert event.payload["merged_task_ids"] == ["north", "south"]
    assert event.payload["accepted_commits"] == Enum.sort(Enum.map(branches, &elem(&1, 2)))

    # The global gates ran at that commit in a private store of their own.
    {:ok, verify} =
      Worktrees.get(
        PlanExecutor.integration_workspace_id(c.execution.execution_id, integrated),
        c.opts
      )

    assert verify.base_commit == integrated

    # Nothing was merged into the person's repository.
    assert git!(c.source, ["rev-parse", "HEAD"]) |> String.trim() == c.base
    assert git!(c.source, ["status", "--porcelain"]) == ""
    assert {:ok, %{disposition: :completed}} = step(c)
  end

  test "a dependent unlocks only after both acceptances and continues from Shoestring's merge" do
    c = unit()
    assert {:ok, %{dispatched: [north, south]}} = step(c)
    commit_and_accept!(c, north)
    assert {:ok, %{disposition: :awaiting_task}} = step(c)
    commit_and_accept!(c, south)

    assert {:ok, %{disposition: :dispatched, plan_task_id: "join"} = join} =
             step(c, admission_event_id: admission!(c.goal).id)

    assert {:ok, %{integration: %{commit: integrated, by: "shoestring"}}} =
             PlanExecutor.status(c.goal.id, c.opts)

    {:ok, tree} = Worktrees.get(join.run_id, c.opts)
    assert tree.base_commit == integrated
    accept!(c, join)
    assert {:ok, %{disposition: :completed}} = step(c)

    assert {:ok, %{completed?: true, accepted: ["join", "north", "south"]}} =
             PlanExecutor.status(c.goal.id, c.opts)
  end

  test "a conflict is never resolved: recorded, aborted, and the person integrates by hand" do
    c = unit(independent_only: true)
    assert {:ok, %{dispatched: [north, south]}} = step(c)
    north_branch = commit_and_accept!(c, north)

    # South also changed north's file, and the person accepted that.
    tree = commit_change!(c, south, "lib/north.ex")
    complete_child!(c.goal, south.run_id)

    assert {:ok, %{disposition: :scope_blocked}} =
             PlanExecutor.complete_task_run(c.goal.id, south.run_id, c.opts)

    assert {:ok, _} =
             ExecutionControl.resolve_scope(c.goal.id, %{
               execution_id: c.execution.execution_id,
               task_id: "south",
               attempt: 1,
               decision: "accept",
               reason: "South needs that change too.",
               command_id: Ecto.UUID.generate(),
               requested_by: "human:operator"
             })

    south_branch =
      {tree.repo_path, tree.branch, git!(tree.path, ["rev-parse", "HEAD"]) |> String.trim()}

    assert {:ok, %{disposition: :blocked, reason: :integration_required, merge: merge}} =
             step(c)

    assert merge["reason"] == "conflict"

    assert {merge["plan_task_id"], merge["files"], merge["merged_task_ids"]} ==
             {"south", ["lib/north.ex"], ["north"]}

    # Aborted: Shoestring's worktree holds no half-done merge.
    {:ok, tree} =
      Worktrees.get(PlanExecutor.merge_workspace_id(c.execution.execution_id, c.base), c.opts)

    assert git!(tree.path, ["status", "--porcelain"]) == ""
    {_, 1} = System.cmd("git", ["rev-parse", "-q", "--verify", "MERGE_HEAD"], cd: tree.path)

    {:ok, status} = PlanExecutor.status(c.goal.id, c.opts)
    assert %{"reason" => "conflict"} = PlanMerge.blocked(c.goal.id, status)
    refute status.completed?

    # Trying again records nothing new.
    assert {:ok, %{disposition: :blocked, merge: ^merge}} = step(c)

    assert Repo.aggregate(
             from(e in TrajectoryEvent,
               where: e.goal_id == ^c.goal.id and e.type == "cobbler.plan.merge.blocked"
             ),
             :count
           ) == 1

    # The person resolves it in their repository and records it, as before.
    integrated = merge_resolving!(c, [north_branch, south_branch])
    assert {:ok, _} = integrate(c, integrated)
    assert {:ok, status} = PlanExecutor.status(c.goal.id, c.opts)
    assert PlanMerge.blocked(c.goal.id, status) == nil
    assert {:ok, %{disposition: :completed, commit: ^integrated}} = step(c)
  end

  test "a merge interrupted by a restart is aborted and redone; merged tasks are not merged twice" do
    c = unit(independent_only: true)
    assert {:ok, %{dispatched: [north, south]}} = step(c)
    {_, _, north_commit} = commit_and_accept!(c, north)
    {south_path, _, south_commit} = commit_and_accept!(c, south)

    # As if stopped part-way: north merged, south's merge begun, not committed.
    id = PlanExecutor.merge_workspace_id(c.execution.execution_id, c.base)

    {:ok, tree} =
      Worktrees.create(c.source, id, c.base,
        worktrees_dir: c.opts[:worktrees_dir],
        private_git: true,
        metadata: %{
          "shoestring.plan:merge" => %{
            "execution_id" => c.execution.execution_id,
            "plan_digest" => c.execution.plan_digest,
            "base" => c.base
          }
        }
      )

    {:ok, %{path: north_path}} = Worktrees.get(north.run_id, c.opts)
    git!(tree.path, ["fetch", north_path, north_commit])

    git!(tree.path, [
      "merge",
      "--no-ff",
      "--no-edit",
      "-m",
      "Merge north: Implement north",
      north_commit
    ])

    git!(tree.path, ["fetch", south_path, south_commit])
    git!(tree.path, ["merge", "--no-ff", "--no-commit", south_commit])

    assert {:ok, %{disposition: :completed, commit: integrated}} = step(c)

    assert git!(tree.path, ["log", "--format=%s", "--first-parent", "#{c.base}..#{integrated}"])
           |> String.split("\n", trim: true) == [
             "Merge south: Implement south",
             "Merge north: Implement north"
           ]
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

  # A human merges each branch, taking the later side of any conflict.
  defp merge_resolving!(c, branches) do
    for {path, branch, _commit} <- branches do
      git!(c.source, ["fetch", path, branch])

      case System.cmd("git", ["merge", "--no-ff", "--no-edit", "FETCH_HEAD"],
             cd: c.source,
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          :ok

        _ ->
          git!(c.source, ["checkout", "--theirs", "."])
          git!(c.source, ["add", "."])
          git!(c.source, ["commit", "--no-edit"])
      end
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
