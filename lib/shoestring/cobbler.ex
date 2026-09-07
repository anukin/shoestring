defmodule Shoestring.Cobbler do
  @moduledoc """
  Cobbler: Quota-aware admission evaluation, deterministic reserve policies,
  and durable admission decision persistence.

  In Milestone 05 (quota-aware MVP foundation), Cobbler evaluates admission
  requests deterministically against capacity observations, candidate capabilities,
  explicit occupancy evidence, and operator confirmations, persisting durable
  `admission.decided` trajectory events without activating automatic dispatch.
  """

  alias Shoestring.Cobbler.{AdmissionDecision, AdmissionEvaluation, AdmissionPolicy}
  alias Shoestring.Harness.CapacitySnapshot

  @doc """
  Evaluates admission for a single candidate provider deterministically.

  Requires explicit `:now` DateTime in `opts`.
  """
  @spec evaluate_admission(
          map(),
          map(),
          CapacitySnapshot.t() | map() | nil,
          AdmissionPolicy.t() | nil,
          keyword()
        ) :: {:ok, AdmissionDecision.t()} | {:error, term()}
  def evaluate_admission(request, candidate, snapshot, policy \\ nil, opts \\ []) do
    AdmissionEvaluation.evaluate(request, candidate, snapshot, policy, opts)
  end

  @doc """
  Evaluates admission across multiple candidate providers in deterministic priority order.
  """
  @spec evaluate_candidates(
          map(),
          [map()],
          map(),
          AdmissionPolicy.t() | nil,
          keyword()
        ) ::
          {:ok, %{selected: AdmissionDecision.t(), all: [AdmissionDecision.t()]}}
          | {:error, term()}
  def evaluate_candidates(request, candidates, snapshots_map, policy \\ nil, opts \\ []) do
    AdmissionEvaluation.evaluate_candidates(request, candidates, snapshots_map, policy, opts)
  end

  @doc "Returns the default admission policy."
  @spec default_policy() :: AdmissionPolicy.t()
  def default_policy, do: AdmissionPolicy.default()
end
