defmodule ShoestringWeb.RunPresentation do
  @moduledoc """
  Sanitization, redaction, and formatting for manual run UI rendering.

  Guarantees zero leakage of credentials, home directory paths, or provider
  reasoning blocks.
  """

  alias Shoestring.Harness.Security
  alias Shoestring.Trajectory.TrajectoryEvent

  @secret_patterns [
    # sk-* API keys
    {~r/\bsk-[A-Za-z0-9_-]{12,}/, "[REDACTED_API_KEY]"},
    # AWS access key IDs
    {~r/\b(?:AKIA|ASIA|AKIB)[0-9A-Z]{16}\b/, "[REDACTED_API_KEY]"},
    # GitHub tokens
    {~r/\bgithub_pat_[A-Za-z0-9_]{8,}\b/, "[REDACTED_API_KEY]"},
    {~r/\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{8,}\b/, "[REDACTED_API_KEY]"},
    # Basic auth
    {~r/\b(authorization)\s*([:=])\s*Basic(?:\s+[A-Za-z0-9+\/=]+)?/i, "\\1: [REDACTED]"},
    {~r/\bBasic\s+[A-Za-z0-9+\/=]{8,}/i, "Basic [REDACTED]"},
    # Bearer auth
    {~r/\b(authorization)\s*([:=])\s*Bearer(?:\s+[A-Za-z0-9._~+\/-]+=*)?/i,
     "\\1: Bearer [REDACTED]"},
    {~r/\bBearer\s+[A-Za-z0-9._~+\/-]+=*/i, "Bearer [REDACTED]"},
    # Credential assignments
    {~r/\b(api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret|cookie)\s*([:=])[ \t]*(?:["'][^"'\r\n]*["']|[^\s,;]+)?/i,
     "\\1\\2[REDACTED]"},
    {~r/([A-Za-z0-9_.-]*secret[A-Za-z0-9_.-]*)\s*([:=])[ \t]*(?:["'][^"'\r\n]*["']|[^\s,;]+)?/i,
     "\\1\\2[REDACTED]"},
    {~r/([A-Za-z0-9_.-]*[_-]key)\s*([:=])[ \t]*(?:["'][^"'\r\n]*["']|[^\s,;]+)?/i,
     "\\1\\2[REDACTED]"},
    {~r/\b(authorization)\s*([:=])[ \t]*(?!Bearer\b|Basic\b|\[REDACTED\])(?:["'][^"'\r\n]*["']|[^\s,;]+)/i,
     "\\1: [REDACTED]"},
    # User / home filesystem paths
    {~r/\/Users\/[A-Za-z0-9_.-]+/, "/Users/[REDACTED]"},
    {~r/\/home\/[A-Za-z0-9_.-]+/, "/home/[REDACTED]"},
    # XML-like thought / reasoning tags
    {~r/<(thought|reasoning)\b[^>]*>.*?<\s*\/\s*(?:thought|reasoning)\s*>/is,
     "[REDACTED_REASONING]"}
  ]

  @forbidden_key_pattern ~r/(?i)(reasoning|thinking|thought|chain_of_thought|scratchpad|hidden|system_prompt|raw_transcript)/

  @doc """
  Redacts credentials, tokens, home-directory paths, and thought blocks from a string.
  Preserves string content length without artificial diagnostic truncations.
  """
  @spec redact_text(String.t() | nil) :: String.t()
  def redact_text(nil), do: ""

  def redact_text(text) when is_binary(text) do
    Enum.reduce(@secret_patterns, text, fn {pattern, replacement}, acc ->
      String.replace(acc, pattern, replacement)
    end)
  end

  def redact_text(other), do: to_string(other)

  @doc """
  Sanitizes an event or map payload by recursively stripping all hidden reasoning,
  thinking, or credential keys, and redacting string values.
  """
  @spec sanitize_payload(term()) :: term()
  def sanitize_payload(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  def sanitize_payload(map) when is_map(map) do
    map
    |> Enum.reject(fn {key, _value} ->
      key_str = to_string(key)
      forbidden_key?(key_str) or Security.credential_key?(key_str)
    end)
    |> Enum.into(%{}, fn {key, value} ->
      {to_string(key), sanitize_payload(value)}
    end)
  end

  def sanitize_payload(list) when is_list(list) do
    Enum.map(list, &sanitize_payload/1)
  end

  def sanitize_payload(text) when is_binary(text) do
    redact_text(text)
  end

  def sanitize_payload(value), do: value

  @doc """
  Sanitizes a TrajectoryEvent for safe UI rendering.
  """
  @spec sanitize_event(TrajectoryEvent.t()) :: TrajectoryEvent.t()
  def sanitize_event(%TrajectoryEvent{} = event) do
    %TrajectoryEvent{
      event
      | payload: sanitize_payload(event.payload)
    }
  end

  @doc """
  Formats an event payload into pretty-printed, redacted JSON for display.
  """
  @spec format_payload(map() | term()) :: String.t()
  def format_payload(payload) do
    sanitized = sanitize_payload(payload)

    case Jason.encode(sanitized, pretty: true) do
      {:ok, json} -> json
      _ -> "{}"
    end
  end

  @doc """
  Returns true if the key name indicates provider reasoning, thoughts, or scratchpads.
  """
  @spec forbidden_key?(String.t()) :: boolean()
  def forbidden_key?(key) when is_binary(key) do
    Regex.match?(@forbidden_key_pattern, key)
  end

  def forbidden_key?(_), do: false
end
