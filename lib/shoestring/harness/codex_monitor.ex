defmodule Shoestring.Harness.CodexMonitor do
  @moduledoc """
  Top-level alias and convenience delegation boundary for
  `Shoestring.Harness.Capacity.CodexMonitor`.
  """

  defdelegate start_link(opts \\ []), to: Shoestring.Harness.Capacity.CodexMonitor

  defdelegate status(server \\ Shoestring.Harness.Capacity.CodexMonitor),
    to: Shoestring.Harness.Capacity.CodexMonitor

  defdelegate last_observation(server \\ Shoestring.Harness.Capacity.CodexMonitor),
    to: Shoestring.Harness.Capacity.CodexMonitor

  defdelegate get_status(server \\ Shoestring.Harness.Capacity.CodexMonitor),
    to: Shoestring.Harness.Capacity.CodexMonitor

  defdelegate read_capacity(server \\ Shoestring.Harness.Capacity.CodexMonitor, timeout \\ 5_000),
    to: Shoestring.Harness.Capacity.CodexMonitor

  defdelegate disconnect(server \\ Shoestring.Harness.Capacity.CodexMonitor),
    to: Shoestring.Harness.Capacity.CodexMonitor

  defdelegate reconnect(server \\ Shoestring.Harness.Capacity.CodexMonitor),
    to: Shoestring.Harness.Capacity.CodexMonitor

  defdelegate provenance(), to: Shoestring.Harness.Capacity.CodexMonitor
  defdelegate support_tier(), to: Shoestring.Harness.Capacity.CodexMonitor
  defdelegate observe(opts_or_server \\ %{}), to: Shoestring.Harness.Capacity.CodexMonitor
  defdelegate observe(server, opts), to: Shoestring.Harness.Capacity.CodexMonitor
end
