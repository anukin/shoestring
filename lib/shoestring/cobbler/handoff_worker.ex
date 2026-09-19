defmodule Shoestring.Cobbler.HandoffWorker do
  @moduledoc """
  Oban delivery worker for durable cross-provider handoff intents.

  The `run.handoff` command row is effect truth; a job on the `handoff`
  queue is a delivery attempt on it. Uniqueness (`period: :infinity` on
  `handoff_id`, mirroring `DispatchWorker` and `WakeupWorker`) reduces
  redundant attempts but never decides whether a handoff may execute:
  `perform/1` delegates to `Shoestring.Cobbler.Handoffs.perform/3`, whose
  own idempotency guard converges a handoff whose pointer already
  committed, and whose refusals are recorded rather than retried blindly.

  ## Outcome mapping

    * `{:ok, %{outcome: :dispatched | :converged}}` → `:ok`. The receiver is
      dispatched (or was already), and the durable dispatch pipeline owns
      the rest.
    * `{:ok, %{outcome: :refused}}` → `:ok`. A refusal is a *recorded
      decision*, not a delivery failure. Retrying it would re-observe the
      provider and re-decide behind the operator's back, so the attempt
      ends here and the intent is settled; a new explicit command is how a
      refused transfer is retried.
    * `{:error, reason}` → `{:error, reason}`, a retriable attempt. This
      covers the genuinely transient cases — a sender Elf still running, a
      claim momentarily held elsewhere, an unreachable probe. The intent
      stays unsettled, so after Oban's attempts are spent
      `Shoestring.Cobbler.Handoffs.reconcile/1` still re-enqueues it at the
      next boot.

  The receiver capacity probe comes from the `:handoff_observe` application
  environment, in the same shapes `WakeupWorker` accepts: a 1-arity fun
  taking the `%{provider_id:, scope:}` scoping map, a 0-arity fun, or an
  `{module, fun, args}` tuple applied with the scoping map appended.
  Without a usable shape the attempt fails closed
  (`{:observation_failed, :missing_observe_fun}`) and nothing is observed,
  admitted or dispatched.
  """

  use Oban.Worker,
    queue: :handoff,
    max_attempts: 5,
    unique: [period: :infinity, states: :incomplete, keys: [:handoff_id]]

  alias Shoestring.Cobbler.Handoffs

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"goal_id" => goal_id, "command_id" => command_id}}) do
    case Handoffs.perform(goal_id, command_id, worker_opts()) do
      {:ok, %{outcome: outcome}} when outcome in [:dispatched, :converged, :refused] -> :ok
      {:ok, _other} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(_job), do: {:error, :invalid_handoff_job}

  defp worker_opts do
    [
      repo: Shoestring.Repo,
      clock: Application.get_env(:shoestring, :dispatch_clock, Shoestring.Harness.SystemClock),
      observe: observe_fun()
    ]
  end

  defp observe_fun do
    case Application.get_env(:shoestring, :handoff_observe) do
      observe_fun when is_function(observe_fun, 0) ->
        observe_fun

      observe_fun when is_function(observe_fun, 1) ->
        observe_fun

      {module, fun_name, args} when is_atom(module) and is_atom(fun_name) and is_list(args) ->
        fn scoping -> apply(module, fun_name, args ++ [scoping]) end

      _other ->
        fn _scoping -> {:error, :missing_observe_fun} end
    end
  end
end
