defmodule Shoestring.Harness.ClaudeMonitor do
  @moduledoc """
  Convenience boundary and alias for `Shoestring.Harness.Capacity.ClaudeMonitor`.
  """

  defdelegate start_link(opts \\ []), to: Shoestring.Harness.Capacity.ClaudeMonitor

  defdelegate receive_status_line(
                server \\ Shoestring.Harness.Capacity.ClaudeMonitor,
                payload,
                opts \\ []
              ),
              to: Shoestring.Harness.Capacity.ClaudeMonitor

  defdelegate current_snapshot(server \\ Shoestring.Harness.Capacity.ClaudeMonitor, opts \\ []),
    to: Shoestring.Harness.Capacity.ClaudeMonitor

  defdelegate status(server \\ Shoestring.Harness.Capacity.ClaudeMonitor),
    to: Shoestring.Harness.Capacity.ClaudeMonitor

  defdelegate disconnect(
                server \\ Shoestring.Harness.Capacity.ClaudeMonitor,
                reason \\ "session_disconnected"
              ),
              to: Shoestring.Harness.Capacity.ClaudeMonitor

  defdelegate reset(server \\ Shoestring.Harness.Capacity.ClaudeMonitor),
    to: Shoestring.Harness.Capacity.ClaudeMonitor

  defdelegate observe(opts \\ %{}), to: Shoestring.Harness.Capacity.ClaudeMonitor
  defdelegate provenance(), to: Shoestring.Harness.Capacity.ClaudeMonitor
  defdelegate support_tier(), to: Shoestring.Harness.Capacity.ClaudeMonitor
  defdelegate child_spec(opts), to: Shoestring.Harness.Capacity.ClaudeMonitor
end
