defmodule Shoestring.Cobbler.PlanFanoutFairnessTest do
  @moduledoc """
  Deterministic economic/fairness simulation over the real reservation and
  fan-out coordinator boundary (no model, no provider, no live Elf).

  Queue policy version 1: each round visits goals in rotating round-robin
  order; within a goal, ready tasks follow declared topological order, and a
  blocked provider never stops another provider's task. Set
  `SHOESTRING_FAIRNESS_REPORT` to write the measured report as JSON.
  """
  use Shoestring.DataCase, async: false
  import Shoestring.Test.PlanFanoutHelpers

  @moduletag timeout: 300_000

  alias Shoestring.Cobbler.{
    PlanCancellation,
    PlanExecutor,
    PlanFanout,
    PlanFanoutDriver,
    Reservations
  }

  alias Shoestring.Test.PlanExecutorHelpers
  alias Shoestring.Trajectory

  @policy %{global_limit: 3, provider_account_limit: 2, goal_limit: 2, account_units: 2}
  @closed_rounds [1, 2]
  @max_rounds 20

  # Scripted outcomes; anything unnamed completes cleanly one round later.
  @outcomes %{
    {0, "north", 1} => :crash,
    {1, "south", 1} => :quota,
    {3, "join", 1} => :cancel
  }

  test "configured limits hold, nothing leaks and unrelated work never waits" do
    goals =
      for {provider, index} <- Enum.with_index([:a, :a, :b, :b]) do
        c =
          fixture(
            reconciliation_opts: [group_probe: fn _ -> :absent end],
            transform_tasks: fn tasks -> Enum.map(tasks, &Map.put(&1, "depends_on", [])) end
          )

        %{index: index, provider: provider, c: c}
      end

    report = simulate(goals)

    assert report.violations == []
    assert report.max_simultaneous.global <= @policy.global_limit
    assert Enum.all?(Map.values(report.max_simultaneous.goal), &(&1 <= @policy.goal_limit))

    assert Enum.all?(
             Map.values(report.max_simultaneous.bucket),
             &(&1 <= @policy.provider_account_limit)
           )

    assert report.unrelated_wait_rounds == 0
    assert report.accepted_regressions == 0
    assert report.leaked_owners == []
    # A verified quota stop releases capacity; its continuation would acquire
    # fresh ownership. The task itself stays unresolved, not replaced.
    assert report.retained_quota_owners == 0
    assert report.quota_sleep_children == 1
    assert report.false_parallel_admissions == 0

    # Every task completes except the quota-stopped and the cancelled one.
    assert report.accepted_total == 12 - 2

    if path = System.get_env("SHOESTRING_FAIRNESS_REPORT") do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(report, pretty: true) <> "\n")
    end
  end

  defp simulate(goals) do
    initial = %{
      round: 0,
      dispatched_at: %{},
      outcome_applied: MapSet.new(),
      max_global: 0,
      max_goal: %{},
      max_bucket: %{},
      violations: [],
      unrelated_wait_rounds: 0,
      limit_wait_rounds: 0,
      accepted: %{},
      accepted_regressions: 0,
      rounds: []
    }

    final =
      Enum.reduce_while(1..@max_rounds, initial, fn round, acc ->
        acc = %{acc | round: round} |> resolve_due(goals)
        acc = dispatch_round(acc, goals)
        if done?(goals), do: {:halt, acc}, else: {:cont, acc}
      end)

    outstanding = Reservations.outstanding()

    quota_runs =
      for g <- goals,
          {:ok, status} = PlanExecutor.status(g.c.goal.id, g.c.opts),
          child <- status.children,
          child.stop_class == :quota_sleep,
          do: child.run_id

    %{
      queue_policy_version: PlanFanoutDriver.policy_version(),
      queue_policy:
        "rotating round-robin over goals; declared task order; provider-blocked tasks skipped",
      reservation_policy: @policy,
      provider_window_closed_rounds: %{"a" => @closed_rounds},
      rounds_run: final.round,
      max_simultaneous: %{
        global: final.max_global,
        goal: final.max_goal,
        bucket: final.max_bucket
      },
      violations: final.violations,
      false_parallel_admissions: length(final.violations),
      unrelated_wait_rounds: final.unrelated_wait_rounds,
      limit_wait_rounds: final.limit_wait_rounds,
      accepted_regressions: final.accepted_regressions,
      accepted_total: final.accepted |> Map.values() |> Enum.sum(),
      leaked_owners: for(o <- outstanding, o.run_id not in quota_runs, do: o.run_id),
      retained_quota_owners: Enum.count(outstanding, &(&1.run_id in quota_runs)),
      quota_sleep_children: length(quota_runs),
      observed_capacity_delta_per_child: nil,
      observed_capacity_delta_reason: "Fake fixtures report no provider capacity consumption",
      rounds: Enum.reverse(final.rounds)
    }
  end

  defp dispatch_round(acc, goals) do
    order = Enum.map(0..3, &Enum.at(goals, rem(&1 + acc.round, 4)))

    {acc, entries} =
      Enum.reduce(order, {acc, []}, fn g, {acc, entries} ->
        before = ready_count(g)
        open? = not (g.provider == :a and acc.round in @closed_rounds)

        result =
          case PlanFanout.dispatch_ready(g.c.goal.id, fanout_opts(g, open?)) do
            {:ok, result} -> result
            {:error, reason} -> %{dispatched: [], blocked: [%{reason: reason}]}
          end

        dispatched = result.dispatched

        acc =
          Enum.reduce(dispatched, acc, fn child, acc ->
            put_in(acc.dispatched_at[{g.index, child.plan_task_id, child.attempt}], {
              acc.round,
              child.run_id
            })
          end)

        acc = measure(acc, goals)
        free? = free_for?(g)

        acc =
          cond do
            before == 0 or dispatched != [] -> acc
            open? and free? -> %{acc | unrelated_wait_rounds: acc.unrelated_wait_rounds + 1}
            true -> %{acc | limit_wait_rounds: acc.limit_wait_rounds + 1}
          end

        {acc,
         entries ++
           [
             %{
               goal: g.index,
               provider: g.provider,
               ready: before,
               dispatched: length(dispatched),
               blocked: Enum.map(result.blocked, &inspect(&1.reason)),
               window_open: open?
             }
           ]}
      end)

    %{
      acc
      | rounds: [
          %{round: acc.round, outstanding: length(Reservations.outstanding()), goals: entries}
          | acc.rounds
        ]
    }
  end

  defp resolve_due(acc, goals) do
    Enum.reduce(acc.dispatched_at, acc, fn {{gi, task, attempt} = key, {round, run_id}}, acc ->
      if round < acc.round and not MapSet.member?(acc.outcome_applied, key) do
        g = Enum.at(goals, gi)
        apply_outcome(g, run_id, Map.get(@outcomes, key, :complete))
        acc = %{acc | outcome_applied: MapSet.put(acc.outcome_applied, key)}
        track_accepted(acc, goals, task, attempt)
      else
        acc
      end
    end)
  end

  defp track_accepted(acc, goals, _task, _attempt) do
    Enum.reduce(goals, acc, fn g, acc ->
      {:ok, status} = PlanExecutor.status(g.c.goal.id, g.c.opts)
      now = length(status.accepted)
      before = Map.get(acc.accepted, g.index, 0)

      regressions =
        if now < before, do: acc.accepted_regressions + 1, else: acc.accepted_regressions

      %{acc | accepted: Map.put(acc.accepted, g.index, now), accepted_regressions: regressions}
    end)
  end

  defp apply_outcome(g, run_id, :complete) do
    complete_child!(g.c.goal, run_id)

    assert {:ok, %{disposition: :accepted}} =
             PlanExecutor.complete_task_run(g.c.goal.id, run_id, g.c.opts)
  end

  defp apply_outcome(g, run_id, :crash) do
    stop!(g, run_id, %{"error_category" => "transport", "error_code" => "process_exited"})

    assert {:ok, %{retry_state: "retry"}} =
             PlanExecutor.complete_task_run(g.c.goal.id, run_id, g.c.opts)
  end

  defp apply_outcome(g, run_id, :quota) do
    stop!(g, run_id, %{"error_category" => "quota_refused", "error_code" => "rate_limit"})
  end

  defp apply_outcome(g, run_id, :cancel) do
    assert {:ok, request} =
             PlanCancellation.request(g.c.goal.id, %{
               execution_id: g.c.execution.execution_id,
               run_id: run_id,
               reason: "Simulated user cancellation.",
               command_id: Ecto.UUID.generate(),
               requested_by: "human:operator"
             })

    assert {:ok, _} =
             PlanCancellation.perform(
               g.c.goal.id,
               request.cancellation_id,
               Keyword.put(g.c.opts, :elf_lookup, fn _ -> nil end)
             )
  end

  defp stop!(g, run_id, failure) do
    for {type, payload} <- [
          {"run.starting", %{}},
          {"run.running", %{"process_id" => "pgid:424242"}},
          {"run.failed", failure}
        ] do
      assert {:ok, _} =
               Trajectory.append(
                 g.c.goal.id,
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
  end

  defp measure(acc, goals) do
    outstanding = Reservations.outstanding()
    global = length(outstanding)
    by_goal = Enum.frequencies_by(outstanding, & &1.goal_id)
    by_bucket = Enum.frequencies_by(outstanding, &"#{&1.provider_id}/#{&1.scope}")

    goal_max =
      Enum.reduce(goals, acc.max_goal, fn g, max ->
        Map.update(
          max,
          g.index,
          Map.get(by_goal, g.c.goal.id, 0),
          &max(&1, Map.get(by_goal, g.c.goal.id, 0))
        )
      end)

    bucket_max = Map.merge(acc.max_bucket, by_bucket, fn _, a, b -> max(a, b) end)

    violations =
      acc.violations ++
        if(global > @policy.global_limit,
          do: [%{round: acc.round, kind: "global", count: global}],
          else: []
        ) ++
        for(
          {goal, n} <- by_goal,
          n > @policy.goal_limit,
          do: %{round: acc.round, kind: "goal", goal: goal, count: n}
        ) ++
        for(
          {bucket, n} <- by_bucket,
          n > @policy.provider_account_limit,
          do: %{round: acc.round, kind: "bucket", bucket: bucket, count: n}
        )

    %{
      acc
      | max_global: max(acc.max_global, global),
        max_goal: goal_max,
        max_bucket: bucket_max,
        violations: violations
    }
  end

  # Capacity this goal could still use: global, goal and its own bucket.
  defp free_for?(g) do
    outstanding = Reservations.outstanding()
    mine = Enum.count(outstanding, &(&1.goal_id == g.c.goal.id))
    bucket = Enum.count(outstanding, &("#{&1.provider_id}/#{&1.scope}" == bucket(g)))

    length(outstanding) < @policy.global_limit and mine < @policy.goal_limit and
      bucket < @policy.provider_account_limit
  end

  defp ready_count(g) do
    case PlanFanout.ready(g.c.goal.id, g.c.opts) do
      {:ok, ready} -> length(ready)
      {:error, _} -> 0
    end
  end

  defp done?(goals) do
    Enum.all?(goals, fn g ->
      {:ok, status} = PlanExecutor.status(g.c.goal.id, g.c.opts)

      ready_count(g) == 0 and
        status.children
        |> Enum.reject(& &1.resolved?)
        |> Enum.all?(&(&1.stop_class in [:quota_sleep, :cancelled]))
    end)
  end

  defp bucket(%{provider: :a}), do: "fake/account:codex"
  defp bucket(%{provider: :b}), do: "fake/account:second"

  defp fanout_opts(g, open?) do
    admit = fn goal_id, _execution, _task, _attempt ->
      cond do
        not open? ->
          {:error, {:execution_admission_blocked, "provider_window_closed"}}

        g.provider == :a ->
          {:ok, admission!(%{g.c.goal | id: goal_id}).id}

        true ->
          # A distinct account bucket for the same provider identity.
          {:ok, admission!(%{g.c.goal | id: goal_id}, %{"scope" => "account:second"}).id}
      end
    end

    Keyword.merge(g.c.opts, reservation_policy: @policy, admission_fun: admit)
  end
end
