defmodule Shoestring.Test.HermeticLifecycleClock do
  use Agent

  @behaviour Shoestring.Harness.Clock

  def start_link(opts) do
    Agent.start_link(fn -> Keyword.fetch!(opts, :now) end, name: __MODULE__)
  end

  @impl true
  def now, do: Agent.get(__MODULE__, & &1)

  def advance(seconds) do
    Agent.get_and_update(__MODULE__, fn now ->
      next = DateTime.add(now, seconds, :second)
      {next, next}
    end)
  end
end
