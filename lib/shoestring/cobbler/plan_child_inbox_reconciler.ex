defmodule Shoestring.Cobbler.PlanChildInboxReconciler do
  @moduledoc "Startup-only child inbox replay and delivery repair; never starts or cancels an Elf."
  use GenServer
  require Logger

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts), do: {:ok, opts, {:continue, :reconcile}}

  @impl true
  def handle_continue(:reconcile, opts) do
    case safe_reconcile(opts) do
      {:ok, %{failures: []}} -> :ok
      _ -> Logger.error("plan child inbox delivery repair failed")
    end

    {:noreply, opts}
  end

  defp safe_reconcile(opts) do
    Shoestring.Cobbler.PlanChildInbox.reconcile(opts)
  rescue
    _ -> {:error, :child_inbox_repair_failed}
  catch
    _, _ -> {:error, :child_inbox_repair_failed}
  end
end
