defmodule Shoestring.Test.ProfileCaptureFake do
  @moduledoc "Fake harness that reports delivered model options to its test owner."
  alias Shoestring.Harness.Fake

  def start(request, opts) do
    ref = make_ref()
    send(Map.fetch!(opts, :observer), {:profile_started, self(), ref, request, opts})

    receive do
      {:continue_profile, ^ref} -> Fake.start(request, opts)
    after
      5_000 -> {:error, :profile_observer_timeout}
    end
  end

  defdelegate resume(prior, request, opts), to: Fake
  defdelegate stream(identity, opts), to: Fake
  defdelegate cancel(identity, opts), to: Fake
  defdelegate status(identity, opts), to: Fake
  defdelegate identity(), to: Fake
  defdelegate probe(opts), to: Fake
end
