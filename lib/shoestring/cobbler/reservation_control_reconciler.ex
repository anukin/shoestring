defmodule Shoestring.Cobbler.ReservationControlReconciler do
  @moduledoc "Startup delivery repair for explicit operator requests; no new recovery decisions."
  use GenServer
  require Logger

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def init(opts), do: {:ok, opts, {:continue, :repair}}

  def handle_continue(:repair, opts) do
    case Shoestring.Cobbler.ReservationControl.repair(opts) do
      {:ok, %{failures: []}} -> :ok
      _ -> Logger.error("reservation recovery delivery repair failed")
    end

    {:noreply, opts}
  end
end
