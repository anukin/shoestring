defmodule Shoestring.Test.FanoutBarrierFake do
  @moduledoc "A message barrier around Fake streaming, so two supervised children can be observed concurrently."
  @behaviour Shoestring.Harness.Adapter
  alias Shoestring.Harness.{Error, Fake}
  @impl true
  defdelegate identity(), to: Fake
  @impl true
  defdelegate capabilities(), to: Fake
  @impl true
  defdelegate probe(opts), to: Fake
  @impl true
  defdelegate start(request, opts), to: Fake
  @impl true
  defdelegate resume(identity, request, opts), to: Fake
  @impl true
  defdelegate send(identity, message, opts), to: Fake
  @impl true
  defdelegate cancel(identity, opts), to: Fake
  @impl true
  defdelegate status(identity, opts), to: Fake

  @impl true
  def stream(identity, opts) do
    Kernel.send(opts.barrier_parent, {:fanout_stream_ready, self(), identity.run_id})

    receive do
      :release_stream -> Fake.stream(identity, opts)
    after
      15_000 ->
        {:error,
         Error.new(:transport, "fixture_barrier_timeout", "Fake stream barrier timed out")}
    end
  end
end
