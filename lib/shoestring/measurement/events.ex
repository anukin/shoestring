defmodule Shoestring.Measurement.Events do
  @moduledoc "Canonical measurement-collection facts: operator-attested windows, no prose."
  alias Shoestring.Harness.Contract

  @providers ~w(codex claude)
  @close_reasons ~w(operator_closed external_use_reported)
  @label ~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/

  def providers, do: @providers
  def close_reasons, do: @close_reasons

  def validate("measurement.collection.opened", payload) do
    if payload["provider_id"] in @providers and label?(payload["scope"]) and
         payload["attestation_version"] == 1 and label?(payload["attested_by"]),
       do: :ok,
       else:
         Contract.invalid(
           :attestation_version,
           "must name a supported provider, scope, attestation and operator label"
         )
  end

  def validate("measurement.collection.closed", payload) do
    if payload["provider_id"] in @providers and label?(payload["scope"]) and
         payload["reason"] in @close_reasons,
       do: :ok,
       else: Contract.invalid(:reason, "must name a supported provider, scope and close reason")
  end

  def validate(_type, _payload), do: :ok

  def label?(value), do: is_binary(value) and Regex.match?(@label, value)
end
