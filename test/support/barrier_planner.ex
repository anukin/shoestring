defmodule Shoestring.Test.BarrierPlanner do
  @moduledoc """
  Hermetic rendezvous planner for real-overlap quota tests.

  Selected through the existing `:adapter` planner opt with a `:fixture`
  map carrying `{:barrier, pid}`. On every invocation it signals
  `{:entered, self()}` to the barrier pid and waits for an explicit
  `:release` message before delegating plan construction to the
  deterministic fixture (with this adapter's own attribution). The waits
  carry generous timeouts purely as deadlock guards — all synchronization
  is message-driven, never sleeps.

  No provider CLI is touched and no network is used. No production code
  references this module: it exercises only the public adapter boundary
  (`identity/0`, `plan/2`, the `:adapter`/`:fixture` opts).
  """

  @behaviour Shoestring.Cobbler.PlannerAdapter

  alias Shoestring.Cobbler.PlannerFixture

  @release_timeout 10_000

  @impl true
  @spec identity() :: %{identity: String.t(), version: String.t(), model: String.t()}
  def identity, do: %{identity: "barrier-planner", version: "1", model: "barrier-1"}

  @impl true
  @spec plan(map(), keyword()) ::
          {:ok, map()} | {:error, {:transport | :invalid_response | :refused, map()}}
  def plan(prompt, opts \\ []) when is_map(prompt) do
    barrier =
      case Keyword.get(opts, :fixture, %{}) do
        %{barrier: pid} when is_pid(pid) -> pid
        _other -> exit({:barrier_missing, opts})
      end

    send(barrier, {:entered, self()})

    receive do
      :release -> :ok
    after
      @release_timeout -> exit(:barrier_release_timeout)
    end

    case PlannerFixture.plan(prompt, Keyword.delete(opts, :fixture)) do
      {:ok, plan} ->
        {:ok,
         Map.put(plan, "planner", %{
           "identity" => "barrier-planner",
           "version" => "1",
           "source_context_refs" => source_refs(prompt)
         })}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp source_refs(prompt) do
    prompt
    |> Map.get("context", [])
    |> Enum.map(&Map.get(&1, "ref", "barrier-ref"))
    |> Enum.take(16)
  end
end
