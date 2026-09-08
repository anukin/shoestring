defmodule Shoestring.Cobbler.WakeupReconciler do
  @moduledoc """
  Runs one durable wakeup repair pass whenever the application starts.

  Mirrors `Shoestring.Harness.Dispatch.Reconciler`: on boot it calls
  `Shoestring.Cobbler.Wakeups.reconcile/1` once (terminal-goal rows are
  cancelled, past-due rows flip to `due`, rows without a live delivery
  attempt get one re-enqueued). It adds no wake semantics of its own — no
  new wakeups are scheduled here, and no timer ever fires from this
  process afterwards.
  """

  use GenServer

  alias Shoestring.Cobbler.Wakeups
  require Logger

  defstruct [:opts, :last_result]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec reconcile_now(GenServer.server()) ::
          {:ok, %{repaired_count: non_neg_integer(), failures: [map()]}} | {:error, term()}
  def reconcile_now(server \\ __MODULE__), do: GenServer.call(server, :reconcile)

  @impl true
  def init(opts), do: {:ok, %__MODULE__{opts: opts, last_result: nil}, {:continue, :reconcile}}

  @impl true
  def handle_continue(:reconcile, state) do
    result = safe_reconcile(state.opts)
    report_result(result)
    {:noreply, %{state | last_result: result}}
  end

  @impl true
  def handle_call(:reconcile, _from, state) do
    result = safe_reconcile(state.opts)
    report_result(result)
    {:reply, result, %{state | last_result: result}}
  end

  defp safe_reconcile(opts) do
    try do
      Wakeups.reconcile(opts)
    rescue
      _error -> {:error, :wakeup_reconciliation_failed}
    catch
      _kind, _reason -> {:error, :wakeup_reconciliation_failed}
    end
  end

  defp report_result({:ok, %{repaired_count: repaired_count, failures: failures}})
       when is_integer(repaired_count) and is_list(failures) do
    if failures != [] do
      Logger.error("durable wakeup reconciliation completed with failures",
        repaired_count: repaired_count,
        failure_count: length(failures)
      )
    end
  end

  defp report_result({:error, _reason}) do
    Logger.error("durable wakeup reconciliation failed")

    :telemetry.execute(
      [:shoestring, :cobbler, :wakeup_reconcile],
      %{repaired_count: 0, failure_count: 1},
      %{result: :error, reason: :wakeup_reconciliation_failed}
    )
  end
end
