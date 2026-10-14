defmodule Shoestring.Cobbler.ReservationWriter do
  @moduledoc """
  Local FIFO delivery for explicit reconciliation writes, without retries.

  Keeps competing native SQLite busy waits from starving a reconciliation
  transaction that needs several evidence reads. SQLite transactions and
  uniqueness still enforce correctness; this mailbox is not ownership state.
  An enclosing coordinator transaction keeps its connection and serialization.
  """
  use GenServer

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, nil, name: Keyword.get(opts, :name, __MODULE__))

  def run(repo, fun) do
    if repo.in_transaction?() do
      fun.()
    else
      case GenServer.call(__MODULE__, {:run, fun}, 30_000) do
        {:returned, result} -> result
        {:raised, kind, reason, stack} -> :erlang.raise(kind, reason, stack)
      end
    end
  end

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_call({:run, fun}, _from, state) do
    reply =
      try do
        {:returned, fun.()}
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      end

    {:reply, reply, state}
  end
end
