defmodule ShoestringWeb.CapacityObservatoryLive do
  use ShoestringWeb, :live_view

  alias Shoestring.Harness.Observatory

  @impl true
  def mount(_params, _session, socket) do
    socket = assign_new(socket, :current_scope, fn -> nil end)
    {:ok, load_observations(socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_observations(socket)}
  end

  defp load_observations(socket) do
    # Fetch all latest observations
    summaries =
      Observatory.latest_observations()
      |> Enum.map(&Observatory.observation_summary/1)

    socket
    |> assign(:page_title, "Capacity Observatory")
    |> stream(:observations, summaries,
      reset: true,
      dom_id: fn s -> "obs-#{s.provider_id}-#{s.invocation_mode}-#{s.scope}" end
    )
  end
end
