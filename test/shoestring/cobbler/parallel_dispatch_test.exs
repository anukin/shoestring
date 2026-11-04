defmodule Shoestring.Cobbler.ParallelDispatchTest do
  @moduledoc """
  Separate single-task IMPLEMENT dispatches at Settings' parallel tasks 2
  (iteration 18): each claims through its own reservation, so two goals run
  side by side, the global limit still holds a third, and the setting cannot
  change while a task waits for its checks. Hermetic: local Git fixtures, the
  Fake provider's identity, no provider CLI, no network.
  """
  use Shoestring.DataCase, async: false
  import Ecto.Query
  import Shoestring.Test.PlanFanoutHelpers

  alias Shoestring.AgentProfiles
  alias Shoestring.Cobbler.{Commands, Parallelism, PlanExecutor, Reservations}
  alias Shoestring.Harness.RunRecord
  alias Shoestring.Test.PlanExecutorHelpers
  alias Shoestring.Trajectory.TrajectoryEvent

  defp parallel!(n) do
    assert {:ok, _} =
             AgentProfiles.save_settings(AgentProfiles.settings(), %{
               "parallel_tasks" => Integer.to_string(n)
             })

    assert Parallelism.tasks() == n
  end

  # A one-task plan whose reservation policy, if any, is the Settings value.
  defp single do
    c = fixture(independent_only: true, transform_tasks: &Enum.take(&1, 1))
    %{c | opts: Keyword.delete(c.opts, :reservation_policy)}
  end

  defp dispatched(c) do
    Repo.all(
      from e in TrajectoryEvent,
        where: e.goal_id == ^c.goal.id and e.type == "cobbler.plan.task.dispatched"
    )
  end

  defp terminal?(c) do
    Repo.exists?(
      from e in TrajectoryEvent,
        where:
          e.goal_id == ^c.goal.id and
            e.type in ~w(run.completed run.failed run.cancelled run.interrupted)
    )
  end

  test "at parallel tasks 2 two goals are both dispatched while neither run is terminal" do
    parallel!(2)
    a = single()
    b = single()

    assert {:ok, %{disposition: :dispatched}} = PlanExecutor.advance(a.goal.id, a.opts)
    # On the single-claim path this second dispatch was refused with
    # {:reservation_blocked, :legacy_claim}.
    assert {:ok, %{disposition: :dispatched}} = PlanExecutor.advance(b.goal.id, b.opts)

    for c <- [a, b] do
      assert [%{payload: payload}] = dispatched(c)
      # Sequential, not a fan-out sibling: no fan-out marker on the run.
      refute Map.has_key?(payload, "dispatch_mode")
      run = Repo.get!(RunRecord, payload["run_id"])
      refute Map.has_key?(run.extensions, "shoestring.fanout:version")
      assert run.extensions[Reservations.key()]
      refute terminal?(c)
      assert {:ok, %{dispatch_mode: :sequential}} = PlanExecutor.status(c.goal.id, c.opts)
    end

    assert Commands.active_claim() == nil

    assert Enum.sort(Enum.map(Reservations.outstanding(), & &1.goal_id)) ==
             Enum.sort([a.goal.id, b.goal.id])
  end

  test "at parallel tasks 1 the second goal still waits for the single task claim" do
    assert Parallelism.tasks() == 1
    a = single()
    b = single()

    assert {:ok, %{disposition: :dispatched}} = PlanExecutor.advance(a.goal.id, a.opts)
    assert {:error, _} = PlanExecutor.advance(b.goal.id, b.opts)
    assert dispatched(b) == []
    assert Commands.active_claim().goal_id == a.goal.id
    assert Reservations.outstanding() == []
  end

  test "at parallel tasks 2 a third goal waits at the global limit" do
    parallel!(2)
    [a, b, c] = [single(), single(), single()]

    assert {:ok, %{disposition: :dispatched}} = PlanExecutor.advance(a.goal.id, a.opts)
    assert {:ok, %{disposition: :dispatched}} = PlanExecutor.advance(b.goal.id, b.opts)

    assert {:error, {:reservation_blocked, :global_limit}} =
             PlanExecutor.advance(c.goal.id, c.opts)

    assert dispatched(c) == []
    assert length(Reservations.outstanding()) == 2
    assert Commands.active_claim() == nil
  end

  test "the setting cannot change while a finished run waits for its checks" do
    parallel!(2)
    a = single()

    assert {:ok, %{disposition: :dispatched}} = PlanExecutor.advance(a.goal.id, a.opts)
    assert [%{payload: %{"run_id" => run_id}}] = dispatched(a)

    # The run ended and its reservation settled at an executor boundary; its
    # checks have not run. Nothing holds a reservation or the task claim.
    complete_child!(a.goal, run_id)

    assert :ok =
             Reservations.reconcile_terminals(a.goal.id,
               group_probe: fn _ -> :absent end,
               now: PlanExecutorHelpers.now()
             )

    assert Reservations.outstanding() == []
    assert Commands.active_claim() == nil
    assert Parallelism.busy?()

    assert {:error, changeset} =
             AgentProfiles.save_settings(AgentProfiles.settings(), %{"parallel_tasks" => "1"})

    assert {"change it when no IMPLEMENT task is running or waiting to run", _} =
             changeset.errors[:parallel_tasks]
  end
end
