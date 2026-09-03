defmodule Shoestring.Harness.Security do
  @moduledoc """
  Centralized security scanner, credential key detector, forbidden content validator,
  and diagnostic redaction utility for capacity observation and fixture processing.
  """

  @max_depth 10
  @max_map_size 64
  @max_list_length 128
  @max_diagnostic_length 200

  @secret_patterns [
    ~r/\bsk-[A-Za-z0-9_-]{12,}/,
    ~r/\bBearer\s+[A-Za-z0-9._~+\/-]+=*/i,
    ~r/\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret|cookie|authorization)\s*[:=]\s*["']?[^"'\s,;]+/i,
    ~r/\/Users\/[A-Za-z0-9_.-]+/,
    ~r/\/home\/[A-Za-z0-9_.-]+/
  ]

  @forbidden_key_substrings [
    "apikey",
    "accesstoken",
    "refreshtoken",
    "authtoken",
    "idtoken",
    "bearertoken",
    "sessiontoken",
    "password",
    "passwd",
    "secret",
    "cookie",
    "authorization",
    "accountid",
    "sessionid",
    "threadid",
    "turnid",
    "rawtranscript",
    "transcript",
    "promptmessages",
    "promptmessage",
    "prompts",
    "prompt",
    "rawoutput",
    "stdout",
    "stderr",
    "modelresponse",
    "responsetext",
    "completiontext",
    "codexhome"
  ]

  @exact_forbidden_keys [
    "token",
    "auth"
  ]

  @json_key_regex ~r/"([A-Za-z0-9_.-]+)"\s*:/

  @doc """
  Returns true if the key name represents a credential, sensitive identifier,
  or forbidden transcript/prompt key.
  """
  @spec credential_key?(atom() | String.t()) :: boolean()
  def credential_key?(key) when is_atom(key) do
    credential_key?(Atom.to_string(key))
  end

  def credential_key?(key) when is_binary(key) do
    normalized =
      key
      |> String.downcase()
      |> String.replace(~r/[-_]/, "")

    normalized in @exact_forbidden_keys or
      Enum.any?(@forbidden_key_substrings, &String.contains?(normalized, &1))
  end

  def credential_key?(_), do: false

  @doc """
  Checks if a binary value contains secrets, auth tokens, or user paths.
  """
  @spec secret_value?(String.t()) :: boolean()
  def secret_value?(value) when is_binary(value) do
    Enum.any?(@secret_patterns, &Regex.match?(&1, value))
  end

  def secret_value?(_), do: false

  @doc """
  Validates an untrusted observation term against resource bounds and security policies.
  Returns `:ok`, `{:error, :payload_too_large}`, `{:error, :payload_too_deep}`,
  or `{:error, :contains_secrets_or_forbidden_content}`.
  """
  @spec validate_observation(term()) ::
          :ok
          | {:error,
             :payload_too_large | :payload_too_deep | :contains_secrets_or_forbidden_content}
  def validate_observation(term) do
    validate_observation_depth(term, 0)
  end

  defp validate_observation_depth(_term, depth) when depth > @max_depth do
    {:error, :payload_too_deep}
  end

  defp validate_observation_depth(%DateTime{}, _depth), do: :ok

  defp validate_observation_depth(value, _depth)
       when is_nil(value) or is_boolean(value) or is_number(value),
       do: :ok

  defp validate_observation_depth(value, _depth) when is_binary(value) do
    if secret_value?(value) do
      {:error, :contains_secrets_or_forbidden_content}
    else
      :ok
    end
  end

  defp validate_observation_depth(value, depth) when is_list(value) do
    if length(value) > @max_list_length do
      {:error, :payload_too_large}
    else
      Enum.reduce_while(value, :ok, fn elem, :ok ->
        case validate_observation_depth(elem, depth + 1) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp validate_observation_depth(value, depth) when is_map(value) do
    if map_size(value) > @max_map_size do
      {:error, :payload_too_large}
    else
      Enum.reduce_while(value, :ok, fn {k, v}, :ok ->
        if credential_key?(k) do
          {:halt, {:error, :contains_secrets_or_forbidden_content}}
        else
          case validate_observation_depth(v, depth + 1) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end
      end)
    end
  end

  defp validate_observation_depth(_other, _depth) do
    {:error, :contains_secrets_or_forbidden_content}
  end

  @doc """
  Boolean helper checking if an observation is valid, bounded, and secret-free.
  """
  @spec safe_observation?(term()) :: boolean()
  def safe_observation?(term) do
    validate_observation(term) == :ok
  end

  @doc """
  Recursively scans a term and returns a list of human-readable security violations.
  """
  @spec scan_term(term()) :: [String.t()]
  def scan_term(term), do: scan_term(term, "")

  defp scan_term(str, path) when is_binary(str) do
    Enum.flat_map(@secret_patterns, fn regex ->
      if Regex.match?(regex, str) do
        [
          "Matched forbidden pattern #{inspect(regex)} at #{path}: #{inspect(String.slice(str, 0, 50))}"
        ]
      else
        []
      end
    end)
  end

  defp scan_term(map, path) when is_map(map) do
    Enum.flat_map(map, fn {k, v} ->
      key_str = to_string(k)
      current_path = if path == "", do: key_str, else: "#{path}.#{key_str}"

      key_violations =
        if credential_key?(key_str) do
          ["Found credential or forbidden key #{inspect(key_str)} at #{current_path}"]
        else
          []
        end

      key_violations ++ scan_term(v, current_path)
    end)
  end

  defp scan_term(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {elem, idx} ->
      scan_term(elem, "#{path}[#{idx}]")
    end)
  end

  defp scan_term(_other, _path), do: []

  @doc """
  Scans raw JSON content for forbidden patterns, user paths, and credential keys.
  Detects quoted and unquoted credential keys even when values are harmless non-sk strings.
  """
  @spec scan_json(String.t()) :: [String.t()]
  def scan_json(raw_json) when is_binary(raw_json) do
    text_violations =
      Enum.flat_map(@secret_patterns, fn regex ->
        if Regex.match?(regex, raw_json) do
          ["Raw text matched #{inspect(regex)}"]
        else
          []
        end
      end)

    raw_key_violations =
      Regex.scan(@json_key_regex, raw_json)
      |> Enum.flat_map(fn [_, key] ->
        if credential_key?(key) do
          ["Raw JSON contains credential key #{inspect(key)}"]
        else
          []
        end
      end)

    term_violations =
      case Jason.decode(raw_json) do
        {:ok, decoded} -> scan_term(decoded)
        _ -> ["Invalid JSON"]
      end

    Enum.uniq(text_violations ++ raw_key_violations ++ term_violations)
  end

  @doc """
  Redacts credential-shaped patterns, tokens, and user paths from CLI error output
  or diagnostic messages. Ensures the result remains bounded within max diagnostic length.
  """
  @spec redact(String.t()) :: String.t()
  def redact(nil), do: ""

  def redact(text) when is_binary(text) do
    text
    |> String.replace(~r/\bsk-[A-Za-z0-9_-]{12,}/, "[REDACTED_API_KEY]")
    |> String.replace(
      ~r/\b(authorization)\s*([:=])\s*Bearer\s+[A-Za-z0-9._~+\/-]+=*/i,
      "\\1: Bearer [REDACTED]"
    )
    |> String.replace(~r/\bBearer\s+[A-Za-z0-9._~+\/-]+=*/i, "Bearer [REDACTED]")
    |> String.replace(
      ~r/\b(api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret|cookie)\s*([:=])\s*["']?[^"'\s,;]+/i,
      "\\1\\2[REDACTED]"
    )
    |> String.replace(
      ~r/\b(authorization)\s*([:=])\s*(?!Bearer\b)["']?[^"'\s,;]+/i,
      "\\1\\2[REDACTED]"
    )
    |> String.replace(~r/\/Users\/[A-Za-z0-9_.-]+/, "/Users/[REDACTED]")
    |> String.replace(~r/\/home\/[A-Za-z0-9_.-]+/, "/home/[REDACTED]")
    |> String.trim()
    |> String.slice(0, @max_diagnostic_length)
  end
end
