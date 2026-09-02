defmodule Shoestring.Test.NonConformingAdapter do
  @moduledoc """
  Deliberately broken adapter fixture. Used by ContractSuiteTest to prove
  that the suite rejects adapters that violate the contract.

  Violations:
  - identity/0: returns a plain map, not an Identity struct
  - capabilities/0: includes :fly (not a valid capability) and is a list not a MapSet
  - probe/1: returns a snapshot with :unlimited compatibility (not a valid atom)
  - start/2: returns {:bad_return, nil} instead of {:ok, RunIdentity.t()}
  - stream/2: events include secrets in extensions; ordinals are not sequential
  """

  @behaviour Shoestring.Harness.Adapter

  @impl true
  def identity do
    # Wrong: plain map instead of %Identity{}, missing required fields
    %{adapter_id: "non.conforming", provider: "test"}
  end

  @impl true
  def capabilities do
    # Wrong: list instead of MapSet, contains :fly which is not a valid capability
    [:cancel, :fly]
  end

  @impl true
  def probe(_opts) do
    # Wrong: map instead of {:ok, %CapacitySnapshot{}}
    %{windows: [], used: "unlimited"}
  end

  @impl true
  def start(_request, _opts) do
    # Wrong: not {:ok, %RunIdentity{}} or {:error, %Error{}}
    {:bad_return, nil}
  end

  @impl true
  def status(_identity, _opts), do: {:ok, %{state: :running}}

  @impl true
  def stream(_identity, _opts) do
    # Wrong: events include secrets; ordinals jump non-sequentially
    {:ok,
     [
       %{
         kind: :output,
         ordinal: 1,
         secret: "Bearer sk-secret-token-abc123",
         run_id: "not-a-uuid"
       },
       %{kind: :result, ordinal: 5}
     ]}
  end
end
