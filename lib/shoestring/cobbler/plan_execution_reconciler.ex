defmodule Shoestring.Cobbler.PlanExecutionReconciler do
  @moduledoc "One startup repair pass for approved execution delivery; never cancels runs."
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts), do: {:ok, opts, {:continue, :reconcile}}

  @impl true
  def handle_continue(:reconcile, opts) do
    case Shoestring.Cobbler.ExecutionControl.reconcile(opts) do
      {:ok, %{failures: []}} -> :ok
      _ -> Logger.error("approved plan execution delivery repair failed")
    end

    {:noreply, opts}
  end
end
