defmodule Shoestring.Test.ArgvCaptureTransport do
  @moduledoc "In-memory launch observation; never spawns a provider or OS command."
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def os_pid(_pid), do: nil
  def terminate_group(pid, _opts), do: GenServer.stop(pid, :normal)

  # A stream-json launch's stdin lines, kept under `:sent` in the options.
  def send_frame(pid, frame), do: GenServer.call(pid, {:send_frame, frame})

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def handle_call({:send_frame, frame}, _from, opts),
    do: {:reply, :ok, Keyword.update(opts, :sent, [frame], &(&1 ++ [frame]))}
end
