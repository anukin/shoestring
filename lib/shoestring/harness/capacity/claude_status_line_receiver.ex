defmodule Shoestring.Harness.Capacity.ClaudeStatusLineReceiver do
  @moduledoc """
  Passive boundary for receiving and parsing Claude Code `statusLine` callbacks.

  Enforces strict bounding:
  - Bounded payload size (<= 64KB for binary payloads).
  - Bounded data structures (depth <= 10, keys <= 64, lists <= 128).
  - Strict secret scanning and forbidden content key rejection.
  - Independent validation of five-hour and seven-day rate-limit windows.
  - Fail-closed handling of malformed input, refusals, and oversized payloads.
  """

  alias Shoestring.Harness.Capacity

  @max_payload_bytes 65_536
  @max_map_keys 64
  @max_depth 10

  @type parse_error ::
          :payload_oversized
          | :malformed_json
          | :malformed_payload
          | :contains_secrets_or_forbidden_content
          | :unsupported_mode
          | {:malformed_window, String.t()}

  @doc """
  Parses and validates a raw statusLine callback payload.

  Accepts binary JSON or an already decoded map.
  Returns `{:ok, parsed_payload}` or `{:error, reason}`.
  """
  @spec parse(binary() | map(), keyword()) :: {:ok, map()} | {:error, parse_error()}
  def parse(input, opts \\ [])

  def parse(binary, opts) when is_binary(binary) do
    if byte_size(binary) > @max_payload_bytes do
      {:error, :payload_oversized}
    else
      case Jason.decode(binary) do
        {:ok, decoded} when is_map(decoded) ->
          parse(decoded, opts)

        {:ok, _non_map} ->
          {:error, :malformed_payload}

        {:error, _reason} ->
          {:error, :malformed_json}
      end
    end
  end

  def parse(map, _opts) when is_map(map) do
    cond do
      map_size(map) > @max_map_keys ->
        {:error, :payload_oversized}

      exceeds_depth?(map, 0) ->
        {:error, :payload_oversized}

      not Capacity.safe_observation?(map) ->
        {:error, :contains_secrets_or_forbidden_content}

      true ->
        sanitize_and_extract(map)
    end
  end

  def parse(_other, _opts), do: {:error, :malformed_payload}

  @doc """
  Validates whether the payload is safe, well-formed, and within bounds.
  """
  @spec validate(binary() | map()) :: :ok | {:error, parse_error()}
  def validate(input) do
    case parse(input) do
      {:ok, _parsed} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Internal Extraction & Normalization Helpers ---

  defp sanitize_and_extract(map) do
    payload = Map.get(map, "payload", map)

    cond do
      not is_map(payload) ->
        {:error, :malformed_payload}

      claude_refusal?(payload) ->
        {:ok,
         %{
           "type" => "result",
           "subtype" => Map.get(payload, "subtype", "rate_limit"),
           "is_error" => true,
           "captured_at" => Map.get(map, "captured_at") || Map.get(map, "observed_at"),
           "scope" => Map.get(map, "scope") || Map.get(payload, "scope"),
           "session_id" => Map.get(map, "session_id") || Map.get(payload, "session_id")
         }}

      claude_provider_error?(payload) ->
        {:ok,
         %{
           "type" => "result",
           "subtype" => Map.get(payload, "subtype", "provider_error"),
           "is_error" => true,
           "captured_at" => Map.get(map, "captured_at") || Map.get(map, "observed_at"),
           "scope" => Map.get(map, "scope") || Map.get(payload, "scope"),
           "session_id" => Map.get(map, "session_id") || Map.get(payload, "session_id")
         }}

      true ->
        extract_status_line_content(map, payload)
    end
  end

  defp extract_status_line_content(map, payload) do
    rate_limits = Map.get(payload, "rate_limits")

    cond do
      is_nil(rate_limits) ->
        # Documented behavior: rate limits absent before first usable response
        {:ok,
         %{
           "model" => extract_model(payload),
           "rate_limits" => nil,
           "version" => extract_version(payload),
           "captured_at" => Map.get(map, "captured_at") || Map.get(map, "observed_at"),
           "scope" => Map.get(map, "scope") || Map.get(payload, "scope"),
           "session_id" => Map.get(map, "session_id") || Map.get(payload, "session_id")
         }}

      not is_map(rate_limits) ->
        {:error, :malformed_payload}

      true ->
        with {:ok, five_hour} <- validate_window("five_hour", Map.get(rate_limits, "five_hour")),
             {:ok, seven_day} <- validate_window("seven_day", Map.get(rate_limits, "seven_day")) do
          cleaned_rate_limits =
            %{}
            |> maybe_put_window("five_hour", five_hour)
            |> maybe_put_window("seven_day", seven_day)
            |> Map.put("spend_limit", Map.get(rate_limits, "spend_limit"))

          {:ok,
           %{
             "model" => extract_model(payload),
             "rate_limits" => cleaned_rate_limits,
             "version" => extract_version(payload),
             "captured_at" => Map.get(map, "captured_at") || Map.get(map, "observed_at"),
             "scope" => Map.get(map, "scope") || Map.get(payload, "scope"),
             "session_id" => Map.get(map, "session_id") || Map.get(payload, "session_id")
           }}
        end
    end
  end

  defp validate_window(_kind, nil), do: {:ok, nil}

  defp validate_window(kind, window) when is_map(window) do
    used = Map.get(window, "used_percentage")
    reset = Map.get(window, "resets_at")

    cond do
      is_nil(used) ->
        {:error, {:malformed_window, kind}}

      not is_number(used) or used < 0 or used > 100 ->
        {:error, {:malformed_window, kind}}

      not is_nil(reset) and not valid_reset_at?(reset) ->
        {:error, {:malformed_window, kind}}

      true ->
        {:ok,
         %{
           "used_percentage" => used,
           "resets_at" => reset
         }}
    end
  end

  defp validate_window(kind, _non_map), do: {:error, {:malformed_window, kind}}

  defp valid_reset_at?(epoch) when is_integer(epoch) and epoch > 0, do: true
  defp valid_reset_at?(%DateTime{}), do: true

  defp valid_reset_at?(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, _, _} -> true
      _ -> false
    end
  end

  defp valid_reset_at?(_), do: false

  defp maybe_put_window(map, _key, nil), do: map
  defp maybe_put_window(map, key, window), do: Map.put(map, key, window)

  defp extract_model(payload) do
    case Map.get(payload, "model") do
      model when is_map(model) ->
        case Map.get(model, "display_name") do
          name when is_binary(name) -> %{"display_name" => name}
          _ -> nil
        end

      name when is_binary(name) ->
        %{"display_name" => name}

      _ ->
        nil
    end
  end

  defp extract_version(payload) do
    case Map.get(payload, "version") do
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  defp claude_refusal?(payload) do
    (Map.get(payload, "is_error") == true and
       Map.get(payload, "subtype") in [
         "rate_limit",
         "rate_limit_reached",
         "rate_limit_refusal",
         "quota_refused"
       ]) or
      Map.get(payload, "subtype") in ["rate_limit_refusal", "quota_refused"]
  end

  defp claude_provider_error?(payload) do
    (Map.get(payload, "is_error") == true and not claude_refusal?(payload)) or
      Map.get(payload, "subtype") in ["provider_error", "process_error"]
  end

  defp exceeds_depth?(_term, depth) when depth > @max_depth, do: true

  defp exceeds_depth?(map, depth) when is_map(map) do
    Enum.any?(map, fn {_k, v} -> exceeds_depth?(v, depth + 1) end)
  end

  defp exceeds_depth?(list, depth) when is_list(list) do
    length(list) > 128 or Enum.any?(list, fn item -> exceeds_depth?(item, depth + 1) end)
  end

  defp exceeds_depth?(_other, _depth), do: false
end
