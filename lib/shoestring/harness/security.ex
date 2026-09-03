defmodule Shoestring.Harness.Security do
  @moduledoc """
  Centralized security scanner, credential key detector, forbidden content validator,
  and diagnostic redaction utility for capacity observation and fixture processing.
  """

  @max_depth 10
  @max_map_size 64
  @max_list_length 128
  @max_diagnostic_length 200

  # Generic secret patterns for arbitrary terms, Contract validation, and observations.
  # Note: Does NOT include /Users or /home paths, which are valid in generic contracts/prompts.
  @generic_secret_patterns [
    {:sk_token, ~r/\bsk-[A-Za-z0-9_-]{12,}/},
    {:bearer_token, ~r/\bBearer\s+[A-Za-z0-9._~+\/-]+=*/i},
    {:basic_auth, ~r/\bBasic\s+[A-Za-z0-9+\/=]{8,}/i},
    # Preserves fail-closed behavior for markers even with absent/empty values
    # e.g., "password: ", "api_key =", "secret:", password="", access_token:""
    {:credential_marker,
     ~r/\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret|cookie|authorization)\s*[:=]/i},
    {:token_assignment, ~r/\btoken\s*[:=]/i}
  ]

  # Filesystem path patterns specifically forbidden in capacity observations and test fixtures.
  @path_patterns [
    {:user_filesystem_path, ~r/\/Users\/[A-Za-z0-9_.-]+/},
    {:home_filesystem_path, ~r/\/home\/[A-Za-z0-9_.-]+/}
  ]

  @capacity_observation_patterns @generic_secret_patterns ++ @path_patterns

  @json_key_regex ~r/"([A-Za-z0-9_.-]+)"\s*:/

  @doc """
  Returns true if the key name represents a credential, sensitive identifier,
  or forbidden transcript/prompt key.

  Uses word-level tokenization to prevent substring false positives on terms like
  `prompt_tokens`, `transcription`, or `secretary`.
  """
  @spec credential_key?(atom() | String.t()) :: boolean()
  def credential_key?(key) when is_atom(key) do
    credential_key?(Atom.to_string(key))
  end

  def credential_key?(key) when is_binary(key) do
    tokens = tokenize_key(key)

    cond do
      tokens == [] ->
        false

      "password" in tokens or "passwd" in tokens ->
        true

      "secret" in tokens ->
        # Matches "secret", "client_secret", "app_secret", etc.
        # But tokens for "secretary" is ["secretary"], so "secret" in tokens is false.
        true

      "cookie" in tokens or "cookies" in tokens ->
        true

      tokens == ["auth"] or "authorization" in tokens or tokens == ["auth", "token"] or
        tokens == ["auth", "header"] or tokens == ["auth", "key"] ->
        true

      tokens == ["api", "key"] or tokens == ["apikey"] ->
        true

      # Auth tokens: "token", "access_token", "refresh_token", "auth_token", "bearer_token", etc.
      # Excludes token metrics like "prompt_tokens", "total_tokens", "max_tokens".
      tokens == ["token"] or
          tokens in [
            ["access", "token"],
            ["refresh", "token"],
            ["auth", "token"],
            ["bearer", "token"],
            ["session", "token"],
            ["id", "token"],
            ["api", "token"]
          ] ->
        true

      # Sensitive identifiers (must have id and identifier category)
      tokens in [
        ["account", "id"],
        ["session", "id"],
        ["thread", "id"],
        ["turn", "id"]
      ] ->
        true

      # Prompts (content, not token counters)
      tokens in [["prompt"], ["prompts"], ["prompt", "message"], ["prompt", "messages"]] ->
        true

      # Transcripts
      tokens in [["transcript"], ["transcripts"], ["raw", "transcript"]] ->
        true

      # Model outputs and system output channels
      tokens in [
        ["raw", "output"],
        ["stdout"],
        ["stderr"],
        ["model", "response"],
        ["response", "text"],
        ["completion", "text"],
        ["codex", "home"]
      ] ->
        true

      true ->
        false
    end
  end

  def credential_key?(_), do: false

  @doc """
  Splits a key name into constituent word tokens by camelCase boundaries and delimiters.
  """
  @spec tokenize_key(String.t()) :: [String.t()]
  def tokenize_key(key) when is_binary(key) do
    key
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
  end

  @doc """
  Checks if a binary value contains generic secrets, auth tokens, or credential assignments.
  Does NOT check /Users or /home filesystem paths (those belong to capacity boundaries).
  """
  @spec secret_value?(String.t()) :: boolean()
  def secret_value?(value) when is_binary(value) do
    Enum.any?(@generic_secret_patterns, fn {_category, regex} ->
      Regex.match?(regex, value)
    end)
  end

  def secret_value?(_), do: false

  @doc """
  Checks if a binary value contains secrets or capacity-forbidden filesystem paths.
  Used specifically for capacity observation and fixture validation.
  """
  @spec capacity_forbidden_value?(String.t()) :: boolean()
  def capacity_forbidden_value?(value) when is_binary(value) do
    Enum.any?(@capacity_observation_patterns, fn {_category, regex} ->
      Regex.match?(regex, value)
    end)
  end

  def capacity_forbidden_value?(_), do: false

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
    if capacity_forbidden_value?(value) do
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
  Recursively scans a term and returns a list of safe human-readable security violations.
  Never includes matched input substrings, secrets, or user paths.
  """
  @spec scan_term(term()) :: [String.t()]
  def scan_term(term), do: scan_term(term, "")

  defp scan_term(str, path) when is_binary(str) do
    Enum.flat_map(@capacity_observation_patterns, fn {category, regex} ->
      if Regex.match?(regex, str) do
        loc = if path == "", do: "root", else: path
        ["Matched forbidden pattern (#{category}) at #{loc}"]
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
  Never includes matched input substrings or secrets in returned diagnostics.
  """
  @spec scan_json(String.t()) :: [String.t()]
  def scan_json(raw_json) when is_binary(raw_json) do
    text_violations =
      Enum.flat_map(@capacity_observation_patterns, fn {category, regex} ->
        if Regex.match?(regex, raw_json) do
          ["Raw text matched forbidden pattern (#{category})"]
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

  Redacts:
  - Authorization Basic credentials (removes entire credential including base64 token)
  - Authorization Bearer tokens
  - Standalone Basic and Bearer tokens
  - sk-* tokens
  - Bare token=... assignments
  - Credential assignments (api_key=, password=, secret=, etc.)
  - User filesystem paths (/Users/..., /home/...)
  """
  @spec redact(String.t()) :: String.t()
  def redact(nil), do: ""

  def redact(text) when is_binary(text) do
    text
    |> String.replace(~r/\bsk-[A-Za-z0-9_-]{12,}/, "[REDACTED_API_KEY]")
    # Redact Authorization Basic header completely, removing base64 token
    |> String.replace(
      ~r/\b(authorization)\s*([:=])\s*Basic(?:\s+[A-Za-z0-9+\/=]+)?/i,
      "\\1: [REDACTED]"
    )
    # Redact bare Basic auth credentials
    |> String.replace(~r/\bBasic\s+[A-Za-z0-9+\/=]{8,}/i, "Basic [REDACTED]")
    # Redact Authorization Bearer header
    |> String.replace(
      ~r/\b(authorization)\s*([:=])\s*Bearer(?:\s+[A-Za-z0-9._~+\/-]+=*)?/i,
      "\\1: Bearer [REDACTED]"
    )
    # Redact bare Bearer token
    |> String.replace(~r/\bBearer\s+[A-Za-z0-9._~+\/-]+=*/i, "Bearer [REDACTED]")
    # Redact bare token= assignments and other credential key assignments
    |> String.replace(
      ~r/\b(api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|secret|cookie)\s*([:=])[ \t]*(?:["'][^"'\r\n]*["']|[^\s,;]+)?/i,
      "\\1\\2[REDACTED]"
    )
    # Redact any other authorization assignments (not already Bearer, Basic, or REDACTED)
    |> String.replace(
      ~r/\b(authorization)\s*([:=])[ \t]*(?!Bearer\b|Basic\b|\[REDACTED\])(?:["'][^"'\r\n]*["']|[^\s,;]+)/i,
      "\\1: [REDACTED]"
    )
    # Redact user filesystem paths
    |> String.replace(~r/\/Users\/[A-Za-z0-9_.-]+/, "/Users/[REDACTED]")
    |> String.replace(~r/\/home\/[A-Za-z0-9_.-]+/, "/home/[REDACTED]")
    |> String.trim()
    |> String.slice(0, @max_diagnostic_length)
  end
end
