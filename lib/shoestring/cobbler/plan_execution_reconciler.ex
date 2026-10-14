defmodule Shoestring.Cobbler.PlanExecutionReconciler do
  @moduledoc """
  One startup repair pass for approved execution delivery; never cancels runs.

  It re-derives planned goal rows from canonical completion facts, repairs
  execution delivery, then re-queues explicit cancellations whose completion
  was never recorded. A failure in one pass is logged without preventing the
  others.
  """
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts), do: {:ok, opts, {:continue, :reconcile}}

  @impl true
  def handle_continue(:reconcile, opts) do
    case safely(fn -> Shoestring.Cobbler.PlanGoalStatus.reconcile(opts) end) do
      {:ok, %{failures: []}} -> :ok
      _ -> Logger.error("planned goal status repair failed")
    end

    case safely(fn -> Shoestring.Cobbler.ExecutionControl.reconcile(opts) end) do
      {:ok, %{failures: []}} -> :ok
      _ -> Logger.error("approved plan execution delivery repair failed")
    end

    case safely(fn -> Shoestring.Cobbler.PlanCancellation.repair(opts) end) do
      {:ok, %{failures: []}} -> :ok
      _ -> Logger.error("plan cancellation delivery repair failed")
    end

    {:noreply, opts}
  end

  defp safely(fun) do
    fun.()
  rescue
    _ -> {:error, :repair_failed}
  catch
    _, _ -> {:error, :repair_failed}
  end
end
