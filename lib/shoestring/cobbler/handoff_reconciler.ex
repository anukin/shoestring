defmodule Shoestring.Cobbler.HandoffReconciler do
  @moduledoc """
  Runs one durable handoff repair pass whenever the application starts.

  Mirrors `Shoestring.Cobbler.WakeupReconciler`: on boot it calls
  `Shoestring.Cobbler.Handoffs.reconcile/1` once, so a handoff intent whose
  delivery attempt was lost (a crash between the command commit and the Oban
  insert, or an Oban insert that failed) gets one back.

  It adds no handoff semantics of its own. No handoff is requested here, no
  provider is observed, no admission is evaluated, and no timer ever fires
  from this process afterwards.
  """

  use GenServer

  alias Shoestring.Cobbler.Handoffs
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
    Handoffs.reconcile(opts)
  rescue
    _error -> {:error, :handoff_reconciliation_failed}
  catch
    _kind, _reason -> {:error, :handoff_reconciliation_failed}
  end

  defp report_result({:ok, %{repaired_count: repaired_count, failures: failures}})
       when is_integer(repaired_count) and is_list(failures) do
    if failures != [] do
      Logger.error("durable handoff reconciliation completed with failures",
        repaired_count: repaired_count,
        failure_count: length(failures)
      )
    end
  end

  defp report_result({:error, _reason}) do
    Logger.error("durable handoff reconciliation failed")
  end
end
