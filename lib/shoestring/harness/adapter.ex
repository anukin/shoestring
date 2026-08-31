defmodule Shoestring.Harness.Adapter do
  @moduledoc "Small behavior surface for normalized harness transport operations."

  alias Shoestring.Harness.{Error, HarnessEvent, Identity, RunIdentity, RunRequest}

  @type capability :: :resume | :send | :cancel | :interactive
  @type result(value) :: {:ok, value} | {:error, Error.t()}

  @callback identity() :: Identity.t()
  @callback capabilities() :: MapSet.t(capability())
  @callback probe(map()) :: result(Shoestring.Harness.CapacitySnapshot.t())
  @callback start(RunRequest.t(), map()) :: result(RunIdentity.t())
  @callback resume(RunIdentity.t(), RunRequest.t(), map()) :: result(RunIdentity.t())
  @callback send(RunIdentity.t(), String.t(), map()) :: result(:accepted)
  @callback cancel(RunIdentity.t(), map()) :: result(:cancelled)
  @callback status(RunIdentity.t(), map()) :: result(map())
  @callback stream(RunIdentity.t(), map()) :: result(Enumerable.t(HarnessEvent.t()))

  @optional_callbacks resume: 3, send: 3, cancel: 2

  @spec supports?(module(), capability()) :: boolean()
  def supports?(adapter, capability) when capability in [:resume, :send, :cancel, :interactive] do
    capability in adapter.capabilities()
  end

  @spec invoke_optional(module(), capability(), atom(), [term()]) :: result(term())
  def invoke_optional(adapter, capability, operation, args) do
    if supports?(adapter, capability) and function_exported?(adapter, operation, length(args)) do
      apply(adapter, operation, args)
    else
      {:error,
       Error.new(
         :unsupported_capability,
         "capability_not_supported",
         "#{operation} requires the #{capability} capability",
         details: %{"shoestring.harness:capability" => Atom.to_string(capability)}
       )}
    end
  end
end
