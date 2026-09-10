defmodule Shoestring.Test.ScriptedProbeFake do
  @moduledoc """
  Fake adapter delegate with scripted per-call probe snapshots.

  Every adapter callback delegates to `Shoestring.Harness.Fake` except
  `probe/1`, which pops the next snapshot from the `:probe_script` Agent
  carried in the adapter opts: the head of `:snapshots` while more than one
  remains, otherwise the last snapshot repeats. Call counts accumulate under
  `:calls`, so lease re-loop tests can prove each renewal re-observed fresh
  capacity instead of reusing one snapshot.

  Hermetic: no provider CLI, no network. The Agent is supervised by the
  test (`start_supervised!/1`) and shared across processes.
  """

  @behaviour Shoestring.Harness.Adapter

  alias Shoestring.Harness.Fake

  @impl true
  def identity, do: Fake.identity()

  @impl true
  def capabilities, do: Fake.capabilities()

  @impl true
  def start(request, opts), do: Fake.start(request, opts)

  @impl true
  def resume(identity, request, opts), do: Fake.resume(identity, request, opts)

  @impl true
  def send(identity, message, opts), do: Fake.send(identity, message, opts)

  @impl true
  def cancel(identity, opts), do: Fake.cancel(identity, opts)

  @impl true
  def status(identity, opts), do: Fake.status(identity, opts)

  @impl true
  def stream(identity, opts), do: Fake.stream(identity, opts)

  @impl true
  def probe(opts) do
    case Map.fetch(opts, :probe_script) do
      {:ok, agent} when is_pid(agent) -> pop(agent)
      _other -> Fake.probe(opts)
    end
  end

  @doc "Returns the probe call count so far."
  @spec calls(pid()) :: non_neg_integer()
  def calls(agent), do: Agent.get(agent, & &1.calls)

  defp pop(agent) do
    Agent.get_and_update(agent, fn
      %{calls: calls, snapshots: [only]} = state ->
        {{:ok, only}, %{state | calls: calls + 1}}

      %{calls: calls, snapshots: [head | rest]} = state ->
        {{:ok, head}, %{state | calls: calls + 1, snapshots: rest}}
    end)
  end
end
