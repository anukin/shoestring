defmodule ShoestringWeb.ModelCatalogWatch do
  @moduledoc "Polls saved model data across CLI/web processes; never starts a provider."
  import Phoenix.LiveView, only: [connected?: 1]

  def schedule(socket) do
    if connected?(socket), do: Process.send_after(self(), :model_catalog_check, 5_000)
    socket
  end
end
