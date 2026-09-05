defmodule ShoestringWeb.RunPresentation do
  @moduledoc """
  Sanitization, redaction, and formatting for manual run UI rendering.

  Guarantees zero leakage of credentials, home directory paths, or provider
  reasoning blocks.
  """

  alias Shoestring.Trajectory.TrajectoryEvent

  @pane_byte_cap 32 * 1024
  @max_rendered_events 200
  @event_head_count 50

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

  @forbidden_key_pattern ~r/(?i)(reasoning|thinking|thought|chain[_-]?of[_-]?thought|scratchpad|hidden|system[_-]?prompt|raw[_-]?transcript)/

  @doc """
  Maximum bytes rendered per text pane (diff, logs, terminal payload).
  Truncation is applied AFTER redaction so a cut can never expose part of a secret.
  """
  @spec pane_byte_cap() :: pos_integer()
  def pane_byte_cap, do: @pane_byte_cap

  @doc """
  Maximum number of events rendered in the DOM window.
  """
  @spec max_rendered_events() :: pos_integer()
  def max_rendered_events, do: @max_rendered_events

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
  Sanitizes an event or map payload by stripping hidden reasoning/thinking
  keys and true credential keys, and redacting secret shapes inside string
  values.

  Evidence channels (`stdout`, `stderr`, `prompt`, `transcript`, `raw_output`,
  `model_response`, `response_text`, `completion_text`, `codex_home`) are
  DISPLAYED with secret redaction applied — never dropped — so verification
  evidence stays visible.
  """
  @spec sanitize_payload(term()) :: term()
  def sanitize_payload(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  def sanitize_payload(map) when is_map(map) do
    map
    |> Enum.reject(fn {key, _value} ->
      key_str = to_string(key)
      forbidden_key?(key_str) or credential_key?(key_str)
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

  @doc """
  Presentation-scoped credential key detector.

  Strips true secret holders (passwords, secrets, tokens, cookies, auth
  headers, API keys) while deliberately ALLOWING evidence channels such as
  `prompt`, `transcript`, `stdout`, `stderr`, `raw_output`, `model_response`,
  `response_text`, `completion_text`, and `codex_home` to render with secret
  redaction applied to their text.
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
        true

      "cookie" in tokens or "cookies" in tokens ->
        true

      tokens == ["auth"] or "authorization" in tokens or tokens == ["auth", "token"] or
        tokens == ["auth", "header"] or tokens == ["auth", "key"] ->
        true

      tokens == ["api", "key"] or tokens == ["apikey"] or tokens == ["private", "key"] or
          tokens == ["privatekey"] ->
        true

      tokens == ["token"] or
          tokens in [
            ["access", "token"],
            ["refresh", "token"],
            ["auth", "token"],
            ["bearer", "token"],
            ["session", "token"],
            ["id", "token"],
            ["api", "token"],
            ["oauth", "token"]
          ] ->
        true

      true ->
        false
    end
  end

  def credential_key?(_), do: false

  @doc false
  @spec tokenize_key(String.t()) :: [String.t()]
  def tokenize_key(key) when is_binary(key) do
    key
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
  end

  @doc """
  Redacts then byte-caps text for bounded pane rendering.

  Returns `{visible_text, omitted_bytes, truncated?}`. The cap is applied
  AFTER redaction so truncation can never bisect a raw secret.
  """
  @spec cap_text(String.t() | nil, pos_integer()) ::
          {String.t(), non_neg_integer(), boolean()}
  def cap_text(text, cap \\ @pane_byte_cap)

  def cap_text(nil, _cap), do: {"", 0, false}

  def cap_text(text, cap) when is_binary(text) and is_integer(cap) and cap > 0 do
    redacted = redact_text(text)

    if byte_size(redacted) <= cap do
      {redacted, 0, false}
    else
      visible = binary_part(redacted, 0, cap) |> trim_trailing_partial_utf8()
      omitted = byte_size(redacted) - byte_size(visible)
      {"#{visible}\n… [truncated, #{omitted} bytes omitted]", omitted, true}
    end
  end

  defp trim_trailing_partial_utf8(bin) do
    if String.valid?(bin) do
      bin
    else
      trim_trailing_partial_utf8(binary_part(bin, 0, byte_size(bin) - 1))
    end
  end

  @doc """
  Windows an event list into a bounded first-N/last-N slice for DOM rendering.

  Returns `{visible_events, total, showing, truncated?}` preserving sequence order.
  """
  @spec window_events([term()], pos_integer(), pos_integer()) ::
          {[term()], non_neg_integer(), non_neg_integer(), boolean()}
  def window_events(events, max \\ @max_rendered_events, head_count \\ @event_head_count)
      when is_list(events) do
    total = length(events)

    if total <= max do
      {events, total, total, false}
    else
      tail_count = max - head_count
      head = Enum.take(events, head_count)
      tail = Enum.take(events, -tail_count)
      {head ++ tail, total, max, true}
    end
  end
end
