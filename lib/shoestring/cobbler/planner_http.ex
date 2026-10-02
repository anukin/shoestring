defmodule Shoestring.Cobbler.PlannerHttp do
  @moduledoc """
  Production planner adapter over an OpenAI-compatible chat-completions endpoint.

  This is the configured boundary: provider, model, and endpoint come from
  application config (`config :shoestring, :planner`), never from the prompt
  and never from model output. The adapter sends the bounded prompt built by
  `Shoestring.Cobbler.PlannerPrompt` with `response_format: %{type: "json_object"}`
  so the model must answer with a single JSON object, then strictly decodes
  that object into the structured plan map the orchestrator validates.

  Transport discipline:

  - HTTP runs through `Req`, the sanctioned client. No other HTTP library
    and no shelling out to a provider CLI.
  - Timeouts are bounded (`receive_timeout`, default 60 seconds) and the
    response body is capped (`max_body`, default 65 536 bytes — the plan
    contract's own byte cap). Oversized output fails the attempt; it is
    never silently truncated into a plan.
  - The API key travels in the request header only. It is read from config
    (`api_key`) or the configured environment variable (`api_key_env`), and
    it is never logged, never persisted, and never echoed in an error.
  - Non-2xx responses, network failures, and timeouts are `{:transport, _}`
    errors: terminal, never repaired, never retried by this module.
  - A 2xx response that is not a JSON object is `{:invalid_response, _}`:
    handled like a schema failure upstream (one bounded repair at most).

  Nothing here touches the database, admission, or approval. Every
  invocation is admitted by the orchestrator first, and every output is
  validated through `PlanContract` plus `PlannerSafety` before anything is
  persisted. No live provider call is needed — or made — to validate this
  boundary; tests exercise the full `plan/2` path against a loopback stub
  server plus `request_body/2` and `decode_response/1` purely.
  """

  @behaviour Shoestring.Cobbler.PlannerAdapter

  @default_receive_timeout 60_000
  @default_max_body 65_536

  @impl true
  @spec identity() :: %{identity: String.t(), version: String.t(), model: String.t()}
  def identity do
    config = config()
    %{identity: "http-planner", version: "1", model: Map.get(config, :model, "unconfigured")}
  end

  @impl true
  @spec plan(map(), keyword()) ::
          {:ok, map()} | {:error, {:transport | :invalid_response | :refused, map()}}
  def plan(prompt, opts \\ []) when is_map(prompt) do
    with {:ok, config} <- configured(opts),
         {:ok, body} <- {:ok, request_body(prompt, config)},
         {:ok, response} <- post(config, body) do
      decode_response(response)
    end
  end

  @doc """
  Resolves the effective planner configuration.

  Application config (`config :shoestring, :planner`) supplies the
  defaults; per-call opts (`:endpoint`, `:model`, `:api_key`,
  `:api_key_env`, `:timeout_ms`, `:max_body`) override them. A missing
  endpoint or credential is `{:error, :planner_not_configured}` — the
  orchestrator reports that before any admission, so an unconfigured
  planner consumes no quota.
  """
  @spec configured(keyword()) :: {:ok, map()} | {:error, :planner_not_configured}
  def configured(opts \\ []) do
    app_config = Application.get_env(:shoestring, :planner, [])

    config = %{
      endpoint: Keyword.get(opts, :endpoint, Keyword.get(app_config, :endpoint)),
      model: Keyword.get(opts, :model, Keyword.get(app_config, :model, "unconfigured")),
      api_key: Keyword.get(opts, :api_key, Keyword.get(app_config, :api_key)),
      api_key_env: Keyword.get(opts, :api_key_env, Keyword.get(app_config, :api_key_env)),
      timeout_ms:
        Keyword.get(
          opts,
          :timeout_ms,
          Keyword.get(app_config, :timeout_ms, @default_receive_timeout)
        ),
      max_body:
        Keyword.get(opts, :max_body, Keyword.get(app_config, :max_body, @default_max_body))
    }

    with :ok <- require_endpoint(config),
         {:ok, config} <- require_credential(config) do
      {:ok, config}
    end
  end

  @doc """
  Builds the chat-completions request body for a prompt (pure).

  The system message fixes the output contract; the user message carries
  the bounded prompt rendering. `max_tokens` is derived from the prompt
  byte cap so the model cannot answer with more than a plan-sized object.
  """
  @spec request_body(map(), map()) :: map()
  def request_body(prompt, config) do
    %{
      "model" => Map.fetch!(config, :model),
      "messages" => [
        %{
          "role" => "system",
          "content" =>
            "You decompose a coding goal into a bounded task plan. " <>
              "Respond with a single JSON object and nothing else. " <>
              "The object must have version, goal, budget, tasks, and planner keys. " <>
              "Every task needs id, title, outcome, acceptance_criteria, gates, " <>
              "checkpoint, and execution bounds. Cite only the trusted gates named " <>
              "in the instructions. Never emit shell strings, reserve, lifecycle, " <>
              "dispatch, approval, or worktree directives."
        },
        %{"role" => "user", "content" => Jason.encode!(prompt)}
      ],
      "response_format" => %{"type" => "json_object"},
      "max_tokens" => 8_192
    }
  end

  @doc """
  Strictly decodes a provider response into a structured plan map (pure).

  Accepts a decoded JSON body map in OpenAI-compatible shape
  (`choices[0].message.content` holding a JSON object string or object).
  Anything else — wrong shape, invalid JSON, a JSON array or scalar — is an
  `invalid_response` error carrying only the failure class, never the raw
  body. A model refusal (`refusal` or `finish_reason: content_filter`) is a
  `refused` error.
  """
  @spec decode_response(map()) ::
          {:ok, map()} | {:error, {:invalid_response | :refused, map()}}
  def decode_response(%{"choices" => [%{"message" => message} | _rest]}) do
    cond do
      refusal?(message) ->
        {:error, {:refused, %{"reason" => "model_refused"}}}

      is_map(message["content"]) ->
        {:ok, message["content"]}

      is_binary(message["content"]) ->
        decode_content(message["content"])

      true ->
        {:error, {:invalid_response, %{"reason" => "missing_content"}}}
    end
  end

  def decode_response(_body), do: {:error, {:invalid_response, %{"reason" => "unexpected_shape"}}}

  # ----------------------------------------------------------------------------
  # Private
  # ----------------------------------------------------------------------------

  defp post(config, body) do
    _ = Application.ensure_all_started(:req)

    config.endpoint
    |> Req.post(
      json: body,
      headers: [{"authorization", "Bearer #{config.api_key}"}, {"accept", "application/json"}],
      decode_body: false,
      receive_timeout: config.timeout_ms,
      retry: false
    )
    |> case do
      {:ok, %Req.Response{status: status, body: raw}} when status in 200..299 ->
        decode_http_body(raw, config)

      {:ok, %Req.Response{status: status}} ->
        {:error, {:transport, %{"reason" => "http_status", "status" => status}}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error,
         {:transport, %{"reason" => "transport", "detail" => reason |> inspect() |> truncate()}}}

      {:error, exception} ->
        {:error,
         {:transport,
          %{"reason" => "request_failed", "detail" => exception |> inspect() |> truncate()}}}
    end
  end

  # The byte cap is enforced on the raw body before JSON decoding:
  # oversized output fails the attempt and is never decoded, truncated,
  # or persisted into a plan.
  defp decode_http_body(body, config)
       when is_binary(body) and byte_size(body) > config.max_body do
    {:error, {:transport, %{"reason" => "oversized_body"}}}
  end

  defp decode_http_body(body, _config) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> {:error, {:invalid_response, %{"reason" => "not_an_object"}}}
      {:error, _reason} -> {:error, {:invalid_response, %{"reason" => "invalid_json"}}}
    end
  end

  defp decode_http_body(_body, _config) do
    {:error, {:invalid_response, %{"reason" => "unexpected_shape"}}}
  end

  defp decode_content(content) do
    case Jason.decode(content) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> {:error, {:invalid_response, %{"reason" => "not_an_object"}}}
      {:error, _reason} -> {:error, {:invalid_response, %{"reason" => "invalid_json"}}}
    end
  end

  defp refusal?(%{"refusal" => refusal}) when is_binary(refusal) and refusal != "", do: true

  defp refusal?(%{"finish_reason" => reason}) when reason in ["content_filter", "refusal"],
    do: true

  defp refusal?(_message), do: false

  defp require_endpoint(%{endpoint: endpoint}) when is_binary(endpoint) and endpoint != "",
    do: :ok

  defp require_endpoint(_config), do: {:error, :planner_not_configured}

  defp require_credential(%{api_key: key} = config) when is_binary(key) and key != "",
    do: {:ok, config}

  defp require_credential(%{api_key_env: env} = config) when is_binary(env) and env != "" do
    case System.get_env(env) do
      key when is_binary(key) and key != "" -> {:ok, Map.put(config, :api_key, key)}
      _other -> {:error, :planner_not_configured}
    end
  end

  defp require_credential(_config), do: {:error, :planner_not_configured}

  defp truncate(text) when byte_size(text) > 300, do: binary_part(text, 0, 300)
  defp truncate(text), do: text

  defp config do
    app_config = Application.get_env(:shoestring, :planner, [])
    %{model: Keyword.get(app_config, :model, "unconfigured")}
  end
end
