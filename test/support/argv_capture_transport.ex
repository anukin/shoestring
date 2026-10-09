defmodule Shoestring.Test.ArgvCaptureTransport do
  @moduledoc "In-memory launch observation; never spawns a provider or OS command."
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def os_pid(_pid), do: nil
  def terminate_group(pid, _opts), do: GenServer.stop(pid, :normal)
  @impl true
  def init(opts), do: {:ok, opts}
end
