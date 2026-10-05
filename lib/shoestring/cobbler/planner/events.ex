defmodule Shoestring.Cobbler.Planner.Events do
  @moduledoc "Strict planner event validation; canonical input/result JSON is revalidated on replay."
  alias Shoestring.Cobbler.PlanContract
  alias Shoestring.Cobbler.Planner.Projection
  alias Shoestring.Harness.{Contract, Security}

  def validate("cobbler.planner.requested", payload) do
    with {:ok, projection} <- Jason.decode(payload["projection_json"]),
         :ok <- Projection.validate(projection),
         :ok <- configuration(payload["configuration"]),
         true <-
           payload["input_digest"] ==
             PlanContract.digest(%{
               "projection" => projection,
               "configuration" => payload["configuration"]
             }) do
      :ok
    else
      _ ->
        Contract.invalid(:input_digest, "must bind a valid bounded projection and configuration")
    end
  end

  def validate("cobbler.planner.attempt.started", payload) do
    if payload["attempt"] in 1..2 and payload["output_token_allowance"] in 1..8192 and
         payload["charged_output_tokens"] ==
           payload["attempt"] * payload["output_token_allowance"],
       do: :ok,
       else: Contract.invalid(:attempt, "must obey the planning budget")
  end

  def validate("cobbler.planner.blocked", payload), do: errors(payload["errors"])

  def validate("cobbler.planner.attempt.finished", payload) do
    with true <- payload["attempt"] in 1..2,
         true <-
           payload["state"] in ~w(ready schema_failed unsafe_proposal transport_failed budget_exceeded),
         true <-
           is_nil(payload["output_tokens"]) ||
             (is_integer(payload["output_tokens"]) && payload["output_tokens"] in 0..8192),
         :ok <- errors(payload["errors"]),
         :ok <- result(payload) do
      :ok
    else
      _ -> Contract.invalid(:base, "must be a bounded planner outcome with a validated result")
    end
  end

  def validate(_, _), do: :ok

  defp result(%{"state" => "ready"} = payload) do
    with {:ok, contract} <- PlanContract.from_canonical_json(payload["plan_content"]),
         true <- contract.digest == payload["plan_digest"],
         [] <- Security.scan_term(contract.content) do
      :ok
    else
      _ -> {:error, :invalid_planner_plan}
    end
  end

  defp result(payload) do
    if Map.has_key?(payload, "plan_content") or Map.has_key?(payload, "plan_digest"),
      do: {:error, :invalid_planner_plan},
      else: :ok
  end

  defp errors(%{"items" => items} = errors)
       when map_size(errors) == 1 and is_list(items) and length(items) <= 8 do
    if Enum.all?(items, fn
         %{"code" => code, "message" => message} = item when map_size(item) == 2 ->
           is_binary(code) and byte_size(code) <= 100 and is_binary(message) and
             byte_size(message) <= 1000 and Security.scan_term(item) == []

         _ ->
           false
       end), do: :ok, else: Contract.invalid(:errors, "must contain bounded safe diagnostics")
  end

  defp errors(_), do: Contract.invalid(:errors, "must contain bounded safe diagnostics")

  defp configuration(config) when is_map(config) do
    expected =
      ~w(adapter model version provider_id scope support_tier max_output_tokens max_attempts max_charged_output_tokens timeout_ms endpoint_digest)

    if Enum.sort(Map.keys(config)) == Enum.sort(expected) and
         config["adapter"] in ["fixture", "ollama"] and config["provider_id"] == config["adapter"] and
         config["scope"] == "planner:#{config["adapter"]}" and
         config["support_tier"] ==
           if(config["adapter"] == "fixture", do: "proactive", else: "reactive_only") and
         config["version"] == "1" and is_binary(config["model"]) and
         byte_size(config["model"]) in 1..400 and
         config["max_attempts"] == 2 and config["max_output_tokens"] in 1..8192 and
         config["max_charged_output_tokens"] == 2 * config["max_output_tokens"] and
         config["timeout_ms"] in 1..300_000 and is_binary(config["endpoint_digest"]) and
         Regex.match?(~r/\A[0-9a-f]{64}\z/, config["endpoint_digest"]) and
         Security.scan_term(config) == [], do: :ok, else: {:error, :invalid_planner_configuration}
  end

  defp configuration(_), do: {:error, :invalid_planner_configuration}
end
