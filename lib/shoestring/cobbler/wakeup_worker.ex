defmodule Shoestring.Cobbler.WakeupWorker do
  @moduledoc """
  Oban delivery worker for durable Cobbler wake intents.

  Jobs are durable delivery attempts on the `wakeup` queue; the
  `cobbler_wakeups` row is effect truth. Uniqueness (`period: :infinity` on
  the durable `:idempotency_key`, mirroring `DispatchWorker`) reduces
  redundant attempts but never determines whether a wake may fire: `perform/1`
  delegates to `Shoestring.Cobbler.Wakeups.perform_wakeup/2`, which no-ops on
  `woken`/`cancelled` rows and re-observes before acting.

  The fresh-snapshot probe comes from the `:wakeup_observe` application
  environment: either a zero-arity fun returning
  `{:ok, CapacitySnapshot.t()} | {:error, reason}` (hermetic callers and
  tests), or an MFA tuple `{module, fun, args}` applied at perform time.
  Production config (`config/runtime.exs`, `:prod` only) points at
  `{Shoestring.Cobbler.WakeupObserve, :observe, []}`, which re-probes
  through the real Observatory ledger. Without either shape the attempt
  fails retriably (`{:error, {:observation_failed, :missing_observe_fun}}`)
  and the intent stays due. Hermetic callers invoke
  `Wakeups.perform_wakeup/2` directly with an explicit `:observe` fun
  instead of going through Oban.
  """

  use Oban.Worker,
    queue: :wakeup,
    max_attempts: 5,
    unique: [period: :infinity, states: :incomplete, keys: [:idempotency_key]]

  alias Shoestring.Cobbler.Wakeups

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"wakeup_id" => wakeup_id} = args}) do
    case Wakeups.perform_wakeup(wakeup_id, worker_opts(args)) do
      {:ok, _summary} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(_job), do: {:error, :invalid_wakeup_job}

  defp worker_opts(args) do
    [
      repo: Shoestring.Repo,
      clock: Application.get_env(:shoestring, :dispatch_clock, Shoestring.Harness.SystemClock),
      observe: observe_fun(),
      request: args["request"],
      candidate: args["candidate"],
      decision_event_id: args["decision_event_id"]
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp observe_fun do
    case Application.get_env(:shoestring, :wakeup_observe) do
      observe_fun when is_function(observe_fun, 0) ->
        observe_fun

      {module, fun_name, args}
      when is_atom(module) and is_atom(fun_name) and is_list(args) ->
        fn -> apply(module, fun_name, args) end

      _other ->
        fn -> {:error, :missing_observe_fun} end
    end
  end
end
