defmodule ShoestringWeb.HealthLive do
  use ShoestringWeb, :live_view

  alias Shoestring.Health

  @impl true
  def mount(_params, _session, socket) do
    {:ok, refresh(socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, refresh(socket)}
  end

  defp refresh(socket) do
    health = Health.check()

    socket
    |> assign(:page_title, "Health")
    |> assign(:health, health)
    |> assign(:ready?, Health.ready?(health))
  end
end
