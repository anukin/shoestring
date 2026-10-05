defmodule Shoestring.Cobbler.Planner.Configuration do
  @moduledoc "Explicit trusted planner configuration. Disabled unless configured."
  alias Shoestring.Cobbler.PlanContract
  alias Shoestring.Harness.Contract

  def load(opts) do
    config = Keyword.get(opts, :config, Application.get_env(:shoestring, :planner, []))

    with true <- is_list(config),
         {:ok, adapter, provider, tier} <- adapter(Keyword.get(config, :adapter, :disabled)),
         {:ok, model} <- Contract.text(Keyword.get(config, :model), :model, max: 100),
         {:ok, limit} <- integer(config, :max_output_tokens, 4096, 1, 8192),
         {:ok, timeout} <- integer(config, :timeout_ms, 60_000, 1, 300_000),
         {:ok, endpoint} <- endpoint(config, provider) do
      public = %{
        "adapter" => provider,
        "model" => model,
        "version" => "1",
        "provider_id" => provider,
        "scope" => "planner:#{provider}",
        "support_tier" => to_string(tier),
        "max_output_tokens" => limit,
        "max_attempts" => 2,
        "max_charged_output_tokens" => limit * 2,
        "timeout_ms" => timeout,
        "endpoint_digest" => PlanContract.digest(%{"endpoint" => endpoint})
      }

      {:ok, %{public: public, adapter: adapter, adapter_opts: config, endpoint: endpoint}}
    else
      false -> {:error, :invalid_planner_configuration}
      error -> error
    end
  end

  def candidate(public) do
    %{
      provider_id: public["provider_id"],
      adapter_id: "planner.#{public["adapter"]}",
      scope: public["scope"],
      support_tier: public["support_tier"],
      compatibility_state: :compatible,
      capabilities: ["read_only"]
    }
  end

  defp adapter(:fixture), do: {:ok, Shoestring.Cobbler.Planner.Fixture, "fixture", :proactive}
  defp adapter(:ollama), do: {:ok, Shoestring.Cobbler.Planner.Ollama, "ollama", :reactive_only}
  defp adapter(:disabled), do: {:error, :planner_disabled}
  defp adapter(_), do: {:error, :unsupported_planner_adapter}

  # Local inference only. No credentials, cloud hosts or automatic downloads.
  defp endpoint(_config, "fixture"), do: {:ok, "fixture"}

  defp endpoint(config, "ollama") do
    endpoint = Keyword.get(config, :endpoint, "http://127.0.0.1:11434")

    case is_binary(endpoint) && URI.parse(endpoint) do
      %URI{scheme: "http", host: host, userinfo: nil, query: nil, fragment: nil, path: path}
      when host in ["127.0.0.1", "localhost", "::1"] and path in [nil, "", "/"] ->
        {:ok, String.trim_trailing(endpoint, "/")}

      _ ->
        {:error, :invalid_planner_endpoint}
    end
  end

  defp integer(config, key, default, min, max) do
    value = Keyword.get(config, key, default)

    if is_integer(value) and value >= min and value <= max,
      do: {:ok, value},
      else: {:error, {:invalid_planner_configuration, key}}
  end
end
