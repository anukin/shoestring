defmodule Shoestring.Trajectory.Redaction do
  @moduledoc "Deterministic redaction for untrusted trajectory text and metadata."

  @redacted "[REDACTED]"
  @secret_value_pattern ~r/(?i)(sk-[a-z0-9][a-z0-9_-]*|ghp_[a-z0-9_]+|bearer\s+[-a-z0-9._~+\/=]+|(?:api[_-]?key|access[_-]?token|password|secret)\s*[:=]\s*[^\s,;]+)/
  @secret_key_pattern ~r/(?i)(token|secret|password|credential|authorization|api[_-]?key|private[_-]?key)/

  @doc "Redacts secret-looking keys and values recursively without changing other values."
  def redact(%DateTime{} = value), do: DateTime.to_iso8601(value)

  def redact(value) when is_map(value) do
    Enum.into(value, %{}, fn {key, nested_value} ->
      key = to_string(key)

      if secret_key?(key) do
        {key, @redacted}
      else
        {key, redact(nested_value)}
      end
    end)
  end

  def redact(value) when is_list(value), do: Enum.map(value, &redact/1)

  def redact(value) when is_binary(value) do
    if String.valid?(value) do
      Regex.replace(@secret_value_pattern, value, @redacted)
    else
      value
    end
  end

  def redact(value), do: value

  defp secret_key?(key), do: Regex.match?(@secret_key_pattern, key)
end
