defmodule Shoestring.Elves.Reconciler do
  @moduledoc """
  Runs one Elf reconciliation pass whenever the application starts.

  Mirrors `Shoestring.Harness.Dispatch.Reconciler`: on boot it calls
  `Shoestring.Elves.reconcile_unfinished/1` once, so a run left `running` by
  a stopped or crashed node is adopted or has its exit recorded instead of
  showing `running` forever. It never spawns, interrupts or retries a run,
  and no timer fires from this process afterwards.
  """

  use GenServer

  alias Shoestring.Elves
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
      Elves.reconcile_unfinished(opts)
    rescue
      _error -> {:error, :elf_reconciliation_failed}
    catch
      _kind, _reason -> {:error, :elf_reconciliation_failed}
    end
  end

  defp report_result({:ok, %{failures: []}}), do: :ok

  defp report_result({:ok, %{repaired_count: repaired_count, failures: failures}}) do
    Logger.error("Elf reconciliation completed with failures",
      repaired_count: repaired_count,
      failure_count: length(failures)
    )
  end

  defp report_result({:error, _reason}), do: Logger.error("Elf reconciliation failed")
end
