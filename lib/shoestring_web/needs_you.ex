defmodule ShoestringWeb.NeedsYou do
  @moduledoc """
  The nav's needs-you count (`Shoestring.Attention.count/0`) for the product
  pages: read on mount, re-read at once when `Shoestring.Attention`
  broadcasts that something changed, and every few seconds for what nothing
  broadcasts (a dispatch becoming held). `on_mount` it, and pass
  `needs_you={@needs_you}` to `Layouts.app`.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  @tick_ms 5_000

  def on_mount(:default, _params, _session, socket) do
    socket =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Shoestring.PubSub, Shoestring.Attention.topic())
        Process.send_after(self(), :needs_you_tick, @tick_ms)
        attach_hook(socket, :needs_you, :handle_info, &info/2)
      else
        socket
      end

    {:cont, assign(socket, :needs_you, Shoestring.Attention.count())}
  end

  # Both messages are the hook's own: the page never sees them, so a page
  # without a catch-all `handle_info/2` is safe.
  defp info({:attention_changed, _session}, socket),
    do: {:halt, assign(socket, :needs_you, Shoestring.Attention.count())}

  defp info(:needs_you_tick, socket) do
    Process.send_after(self(), :needs_you_tick, @tick_ms)
    {:halt, assign(socket, :needs_you, Shoestring.Attention.count())}
  end

  defp info(_message, socket), do: {:cont, socket}
end
