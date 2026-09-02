defmodule Shoestring.Harness.Dispatch.Reconciler do
  @moduledoc "Runs one durable dispatch repair pass whenever the application starts."

  use GenServer

  alias Shoestring.Harness.Dispatches

  defstruct [:opts, :last_result]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec reconcile_now(GenServer.server()) :: {:ok, non_neg_integer()} | {:error, term()}
  def reconcile_now(server \\ __MODULE__), do: GenServer.call(server, :reconcile)

  @impl true
  def init(opts), do: {:ok, %__MODULE__{opts: opts, last_result: nil}, {:continue, :reconcile}}

  @impl true
  def handle_continue(:reconcile, state) do
    {:noreply, %{state | last_result: Dispatches.reconcile(state.opts)}}
  end

  @impl true
  def handle_call(:reconcile, _from, state) do
    result = Dispatches.reconcile(state.opts)
    {:reply, result, %{state | last_result: result}}
  end
end
