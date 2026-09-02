defmodule Shoestring.Harness.Dispatch.Reconciler do
  @moduledoc "Runs one durable dispatch repair pass whenever the application starts."

  use GenServer

  alias Shoestring.Harness.Dispatches
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
      Dispatches.reconcile(opts)
    rescue
      _error -> {:error, :dispatch_reconciliation_failed}
    catch
      _kind, _reason -> {:error, :dispatch_reconciliation_failed}
    end
  end

  defp report_result({:ok, %{repaired_count: repaired_count, failures: failures}})
       when is_integer(repaired_count) and is_list(failures) do
    if failures != [] do
      Logger.error("durable dispatch reconciliation completed with failures",
        repaired_count: repaired_count,
        failure_count: length(failures)
      )
    end
  end

  defp report_result({:error, _reason}) do
    Logger.error("durable dispatch reconciliation failed")

    :telemetry.execute(
      [:shoestring, :harness, :dispatch_reconcile],
      %{repaired_count: 0, failure_count: 1},
      %{result: :error, reason: :dispatch_reconciliation_failed}
    )
  end
end
