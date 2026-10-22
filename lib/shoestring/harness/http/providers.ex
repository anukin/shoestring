defmodule Shoestring.Harness.HTTP.Providers do
  @moduledoc "Frozen text-only request construction and visible-output parsing. No tools or hidden reasoning are retained."
  alias Shoestring.{ApiSpend, Harness.HTTP.Transport}

  def configuration(provider, now \\ DateTime.utc_now())

  def configuration("openai_responses", now) do
    with {:ok, config} <- ApiSpend.policy(),
         {:ok, quote, _} <- ApiSpend.Pricing.quote(config, now),
         true <- quote["output_token_limit"] >= 16 do
      {:ok, config}
    else
      _ -> {:error, :api_policy_not_compatible}
    end
  end

  def configuration("ollama_local", _now) do
    config = Application.get_env(:shoestring, :local_execution, %{})

    with true <- is_map(config) and config[:enabled] == true,
         true <- config[:cloud_disabled_confirmed] == true,
         true <-
           is_binary(config[:server_version]) and
             Regex.match?(~r/\A\d+\.\d+\.\d+\z/, config[:server_version]),
         true <-
           is_binary(config[:model]) and
             Regex.match?(~r/\A[a-zA-Z0-9_.:-]{1,100}\z/, config[:model]),
         true <- not String.contains?(config[:model], ["cloud", "/"]),
         true <-
           is_binary(config[:model_digest]) and
             Regex.match?(~r/\A[0-9a-f]{64}\z/, config[:model_digest]),
         true <- is_integer(config[:context_tokens]) and config[:context_tokens] in 128..131_072,
         true <- is_integer(config[:max_output_tokens]) and config[:max_output_tokens] in 1..8192 do
      {:ok, config}
    else
      _ -> {:error, :local_execution_not_configured}
    end
  end

  def execute("openai_responses", request, config, opts, quote) do
    key = System.get_env("OPENAI_API_KEY")

    if is_binary(key) and key != "" do
      body = %{
        "model" => quote["model"],
        "input" => request.prompt,
        "store" => false,
        "background" => false,
        "stream" => false,
        "tools" => [],
        "tool_choice" => "none",
        "service_tier" => "default",
        "truncation" => "disabled",
        "reasoning" => %{"effort" => "none"},
        "max_output_tokens" => quote["output_token_limit"]
      }

      result =
        transport(opts).request(
          :post,
          "https://api.openai.com/v1/responses",
          body,
          [{"authorization", "Bearer " <> key}],
          opts
        )

      parse_api(result, config[:model])
    else
      {:error, :authentication_required, nil}
    end
  end

  def execute("ollama_local", request, config, opts, _) do
    # The literal loopback endpoint alone does not establish local inference.
    # Operator cloud-disable attestation and pinned local metadata are required.
    base = "http://127.0.0.1:11434"
    transport = transport(opts)

    with true <-
           byte_size(request.prompt) + config[:max_output_tokens] + 16 <= config[:context_tokens],
         {:ok, 200, %{"version" => version}} <-
           transport.request(:get, base <> "/api/version", nil, [], opts),
         true <- version == config[:server_version],
         {:ok, 200, tags} <- transport.request(:get, base <> "/api/tags", nil, [], opts),
         models when is_list(models) <- tags["models"],
         true <- Enum.any?(models, &local_model?(&1, config)),
         {:ok, 200, details} <-
           transport.request(:post, base <> "/api/show", %{"model" => config[:model]}, [], opts),
         %{"format" => "gguf"} <- details["details"],
         nil <- details["remote_host"],
         nil <- details["remote_model"] do
      body = %{
        "model" => config[:model],
        "prompt" => request.prompt,
        "stream" => false,
        "think" => false,
        "raw" => true,
        "options" => %{
          "num_ctx" => config[:context_tokens],
          "num_predict" => config[:max_output_tokens]
        }
      }

      case transport.request(:post, base <> "/api/generate", body, [], opts) do
        {:ok, 200, %{"done" => true, "done_reason" => "stop", "response" => text} = response}
        when is_binary(text) ->
          if response["model"] == config[:model],
            do: {:ok, text, nil},
            else: {:error, :http_schema_incompatible, nil}

        {:ok, status, _} ->
          {:error, status_reason(status), nil}

        {:error, reason} ->
          {:error, reason, nil}
      end
    else
      _ -> {:error, :local_model_not_verified, nil}
    end
  end

  defp local_model?(
         %{"name" => name, "digest" => digest, "size" => size, "details" => %{"format" => "gguf"}} =
           model,
         config
       ) do
    name == config[:model] and digest == config[:model_digest] and is_integer(size) and size > 0 and
      is_nil(model["remote_host"]) and is_nil(model["remote_model"])
  end

  defp local_model?(_, _), do: false
  defp transport(opts), do: Map.get(opts, :transport, Transport)

  defp parse_api({:ok, 200, %{"model" => model, "output" => output} = body}, model)
       when is_list(output) do
    usage =
      Map.take(if(is_map(body["usage"]), do: body["usage"], else: %{}), [
        "input_tokens",
        "output_tokens"
      ])

    text =
      for %{"type" => "message", "role" => "assistant", "content" => content} <- output,
          is_list(content),
          %{"type" => "output_text", "text" => text} <- content,
          is_binary(text),
          do: text

    supported =
      body["service_tier"] == "default" and
        Enum.all?(output, &(is_map(&1) and &1["type"] in ["message", "reasoning"]))

    if supported and body["status"] == "completed" and text != [],
      do: {:ok, Enum.join(text, "\n"), usage},
      else: {:error, :http_incomplete, if(supported, do: usage, else: nil)}
  end

  defp parse_api({:ok, status, _}, _), do: {:error, status_reason(status), nil}
  defp parse_api({:error, reason}, _), do: {:error, reason, nil}
  defp status_reason(status) when status in [401, 403], do: :authentication_required
  defp status_reason(429), do: :quota_refused
  defp status_reason(_), do: :http_schema_incompatible
end
