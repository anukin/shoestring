defmodule Shoestring.Cobbler.PlanFanoutDriver do
  @moduledoc """
  Production choice between sequential execution and the fan-out coordinator.

  Fan-out is off unless trusted configuration enables it
  (`config :shoestring, :plan_fanout, enabled: true`). No plan or model field
  selects it. The reservation policy is `:plan_reservation_policy`, and every
  limit and unit defaults to one, so raising concurrency is an explicit
  operator decision.

  Selection is deterministic (queue policy version 1). A new execution uses
  fan-out only when the policy admits at least two concurrent children, at
  least two first attempts are ready, and the independence assessment is
  eligible. Otherwise it runs the ordinary
  sequential executor: uncertain independence defaults to sequential work.
  Once a child is dispatched, the canonical dispatch mode fixes the choice
  for that execution.

  In fan-out mode each step admits ready first attempts and bounded
  replacements, then completes the execution only when every required task
  is accepted, no child is unresolved, and the accepted commits are
  integrated. Dependents whose inputs are not yet at the approved base wait
  for a human-recorded integration (`Shoestring.Cobbler.PlanIntegration`);
  after it, remaining work continues sequentially from that commit. Children awaiting a continuation keep the step waiting.
  Cancelled, interrupted, conflicting or unintegrated work blocks for an
  operator. This module never merges branches, extends a deadline into an
  interruption, or replaces work that a quota stop or cancellation ended.
  """

  alias Shoestring.Cobbler.{PlanExecutor, PlanFanout, ReservationPolicy}

  @policy_version 1
  @operator_classes [:cancelled, :interrupted]

  def policy_version, do: @policy_version

  def enabled?(config \\ Application.get_env(:shoestring, :plan_fanout, [])),
    do: Keyword.get(config, :enabled, false) == true

  @spec step(Ecto.UUID.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def step(goal_id, opts) do
    with {:ok, status} <- PlanExecutor.status(goal_id, opts) do
      cond do
        status[:planned?] == false ->
          PlanExecutor.resume(goal_id, opts)

        status.completed? ->
          {:ok, %{disposition: :completed, execution: status.execution}}

        status.cancelled? ->
          {:error, :execution_cancelled}

        # After a human records an integration covering every fan-out result,
        # remaining dependent work continues sequentially from that commit.
        status.dispatch_mode == :fanout_v1 and not is_nil(status.integration) ->
          PlanExecutor.resume(goal_id, opts)

        status.dispatch_mode == :fanout_v1 ->
          coordinate(goal_id, opts)

        status.children == [] and
          enabled?(
            Keyword.get(opts, :plan_fanout, Application.get_env(:shoestring, :plan_fanout, []))
          ) and
            initial_fanout?(goal_id, opts) ->
          case coordinate(goal_id, opts) do
            {:ok, %{reason: :independence_unverified}} -> PlanExecutor.resume(goal_id, opts)
            result -> result
          end

        true ->
          PlanExecutor.resume(goal_id, opts)
      end
    end
  end

  # Fan-out must be able to run two children at once; with the default
  # limits of one it would only add integration work, so sequential wins.
  defp initial_fanout?(goal_id, opts) do
    opts = fanout_opts(opts)

    with {:ok, policy} <- ReservationPolicy.new(Keyword.fetch!(opts, :reservation_policy)),
         true <- concurrent?(policy),
         {:ok, ready} <- PlanFanout.ready(goal_id, opts) do
      Enum.count(ready, fn {_task, attempt} -> attempt == 1 end) >= 2
    else
      _ -> false
    end
  end

  defp concurrent?(policy) do
    min(policy.global_limit, min(policy.provider_account_limit, policy.goal_limit)) >= 2 and
      policy.account_units >= 2 * policy.task_units
  end

  defp coordinate(goal_id, opts) do
    case PlanFanout.dispatch_ready(goal_id, fanout_opts(opts)) do
      {:ok, %{disposition: :blocked, reason: :independence_unverified} = result} ->
        {:ok,
         %{disposition: :blocked, reason: :independence_unverified, decision: result.decision}}

      {:ok, %{dispatched: [_ | _]} = result} ->
        {:ok, Map.put(result, :disposition, :dispatched)}

      {:ok, result} ->
        settle(goal_id, result, opts)

      {:error, :fanout_scope_resolution_required} ->
        {:ok, %{disposition: :blocked, reason: :scope_resolution_required}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp settle(goal_id, result, opts) do
    with {:ok, status} <- PlanExecutor.status(goal_id, opts) do
      active = status.active_children
      classes = Enum.map(status.children, &{&1.run_id, &1.stop_class}) |> Map.new()

      cond do
        active == [] ->
          case PlanExecutor.complete_fanout(goal_id, opts) do
            {:ok, %{disposition: :blocked, reason: :fanout_work_outstanding}} ->
              reason =
                if Enum.any?(result.blocked, &(&1.reason == :fanout_inputs_require_integration)),
                  do: :integration_required,
                  else: :needs_user

              {:ok, %{disposition: :blocked, reason: reason, blocked: result.blocked}}

            other ->
              other
          end

        Enum.all?(active, &(Map.get(classes, &1.run_id) in @operator_classes)) ->
          {:ok, %{disposition: :blocked, reason: :operator_continuation_required}}

        true ->
          {:ok, %{disposition: :awaiting_task, blocked: result.blocked}}
      end
    end
  end

  defp fanout_opts(opts) do
    policy =
      Keyword.get(opts, :reservation_policy) ||
        Application.get_env(:shoestring, :plan_reservation_policy) ||
        ReservationPolicy.to_map(%ReservationPolicy{})

    Keyword.merge(opts, fanout_enabled: true, reservation_policy: policy)
  end
end
