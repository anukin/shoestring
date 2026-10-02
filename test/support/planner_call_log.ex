defmodule Shoestring.Test.PlannerCallLog do
  @moduledoc """
  Hermetic invocation log for the fixture planner.

  The fixture sends `{:planner_call, prompt, attempt}` here on every
  invocation. Tests assert on the count to prove quota-blocked requests
  invoke zero times and bounded repair invokes at most twice — and on the
  prompts to prove repair carries the bounded error summaries.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, [], opts)

  @spec calls(pid()) :: [{map(), pos_integer()}]
  def calls(pid), do: GenServer.call(pid, :calls)

  @spec count(pid()) :: non_neg_integer()
  def count(pid), do: GenServer.call(pid, :count)

  @impl true
  def init(_opts), do: {:ok, []}

  @impl true
  def handle_info({:planner_call, prompt, attempt}, calls),
    do: {:noreply, [{prompt, attempt} | calls]}

  @impl true
  def handle_call(:calls, _from, calls), do: {:reply, Enum.reverse(calls), calls}
  def handle_call(:count, _from, calls), do: {:reply, length(calls), calls}
end
