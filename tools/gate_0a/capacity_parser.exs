defmodule Shoestring.Gate0A.CapacityParser do
  @default_freshness_seconds 300

  @spec parse_json(atom() | String.t(), String.t(), keyword()) :: map()
  def parse_json(provider, json, opts \\ []) do
    case Jason.decode(json) do
      {:ok, fixture} -> parse(provider, fixture, opts)
      {:error, _reason} -> unknown(provider, "malformed_json", opts)
    end
  end

  @spec parse(atom() | String.t(), map(), keyword()) :: map()
  def parse(provider, fixture, opts \\ [])

  def parse(provider, fixture, opts) when is_map(fixture) do
    provider = provider_name(provider)
    payload = Map.get(fixture, "payload", fixture)
    observed_at = Map.get(fixture, "captured_at") || Map.get(fixture, "observed_at")
    now = Keyword.get(opts, :now, DateTime.utc_now())
    freshness_seconds = Keyword.get(opts, :freshness_seconds, @default_freshness_seconds)

    case provider do
      "codex" -> parse_codex(payload, provider, observed_at, now, freshness_seconds)
      "claude" -> parse_claude(payload, provider, observed_at, now, freshness_seconds)
      _ -> unknown(provider, "unsupported_provider", opts)
    end
  end

  def parse(provider, _fixture, opts),
    do: unknown(provider_name(provider), "malformed_fixture", opts)

  defp parse_codex(payload, provider, observed_at, now, freshness_seconds) do
    rate_limits =
      get_in(payload, ["result", "rateLimits"]) ||
        get_in(payload, ["params", "rateLimits"]) ||
        Map.get(payload, "rateLimits")

    reset_credits = get_in(payload, ["result", "rateLimitResetCredits"])

    source_event =
      if Map.get(payload, "method") == "account/rateLimits/updated",
        do: "update_notification",
        else: "explicit_read"

    with rate_limits when is_map(rate_limits) <- rate_limits,
         {:ok, primary} <- parse_codex_window(Map.get(rate_limits, "primary")),
         {:ok, secondary} <- parse_codex_window(Map.get(rate_limits, "secondary")) do
      finish(
        provider,
        source_event,
        observed_at,
        now,
        freshness_seconds,
        %{
          primary: primary,
          secondary: secondary,
          rate_limit_reached_type: string_or_nil(Map.get(rate_limits, "rateLimitReachedType")),
          spend_control_reached: boolean_or_nil(Map.get(rate_limits, "spendControlReached")),
          plan_type: string_or_nil(Map.get(rate_limits, "planType")),
          reset_credit_count: reset_credit_count(reset_credits),
          reset_credit_detail_state: reset_credit_detail_state(payload)
        }
      )
    else
      nil ->
        unknown(provider, "missing_rate_limits", %{
          now: now,
          observed_at: observed_at,
          freshness_seconds: freshness_seconds
        })

      {:error, reason} ->
        unknown(provider, normalize_reason(reason), %{
          now: now,
          observed_at: observed_at,
          freshness_seconds: freshness_seconds
        })

      _ ->
        unknown(provider, "malformed_rate_limits", %{
          now: now,
          observed_at: observed_at,
          freshness_seconds: freshness_seconds
        })
    end
  end

  defp parse_claude(payload, provider, observed_at, now, freshness_seconds) do
    rate_limits = Map.get(payload, "rate_limits")
    source_event = "status_line_input"

    cond do
      claude_rate_limit_refusal?(payload) ->
        %{
          provider: provider,
          state: "refused",
          availability: "refused",
          confidence: "medium",
          source_event: "headless_result_error",
          observed_at: observed_at,
          freshness: freshness(observed_at, now, freshness_seconds),
          windows: %{},
          details: %{subtype: Map.get(payload, "subtype")},
          reason: "cli_reported_rate_limit_refusal_without_capacity_snapshot"
        }

      is_nil(rate_limits) ->
        unknown(
          provider,
          "rate_limits_absent_before_first_response_or_unsupported_subscription",
          %{
            now: now,
            observed_at: observed_at,
            freshness_seconds: freshness_seconds
          }
        )

      not is_map(rate_limits) ->
        unknown(provider, "malformed_rate_limits", %{
          now: now,
          observed_at: observed_at,
          freshness_seconds: freshness_seconds
        })

      true ->
        with {:ok, five_hour} <- parse_claude_window(Map.get(rate_limits, "five_hour")),
             {:ok, seven_day} <- parse_claude_window(Map.get(rate_limits, "seven_day")),
             {:ok, spend_limit} <- parse_claude_window(Map.get(rate_limits, "spend_limit")) do
          finish(
            provider,
            source_event,
            observed_at,
            now,
            freshness_seconds,
            %{five_hour: five_hour, seven_day: seven_day, spend_limit: spend_limit}
          )
        else
          {:error, _reason} ->
            unknown(provider, "malformed_claude_window", %{
              now: now,
              observed_at: observed_at,
              freshness_seconds: freshness_seconds
            })
        end
    end
  end

  defp parse_codex_window(nil), do: {:ok, nil}

  defp parse_codex_window(window) when is_map(window) do
    with {:ok, used_percent} <- required_percentage(window, "usedPercent"),
         {:ok, duration} <- optional_integer(window, "windowDurationMins"),
         {:ok, resets_at} <- optional_integer(window, "resetsAt") do
      {:ok,
       %{
         used_percent: used_percent,
         remaining_percent: 100 - used_percent,
         window_duration_minutes: duration,
         resets_at: resets_at
       }}
    end
  end

  defp parse_codex_window(_window), do: {:error, "malformed_codex_window"}

  defp parse_claude_window(nil), do: {:ok, nil}

  defp parse_claude_window(window) when is_map(window) do
    with {:ok, used_percent} <- required_percentage(window, "used_percentage"),
         {:ok, resets_at} <- required_integer(window, "resets_at") do
      {:ok,
       %{
         used_percent: used_percent,
         remaining_percent: 100 - used_percent,
         resets_at: resets_at
       }}
    end
  end

  defp parse_claude_window(_window), do: {:error, "malformed_claude_window"}

  defp finish(provider, source_event, observed_at, now, freshness_seconds, details) do
    freshness = freshness(observed_at, now, freshness_seconds)
    windows = details |> Map.take([:primary, :secondary, :five_hour, :seven_day, :spend_limit])

    required_keys =
      if Map.has_key?(details, :five_hour),
        do: [:five_hour, :seven_day],
        else: [:primary, :secondary]

    required_windows = Map.take(windows, required_keys)
    valid_windows = required_windows |> Map.values() |> Enum.count(&is_map/1)
    missing_windows = required_windows |> Map.values() |> Enum.count(&is_nil/1)
    malformed? = Enum.any?(windows, &match?({:error, _}, &1))

    details = Map.drop(details, [:primary, :secondary, :five_hour, :seven_day, :spend_limit])
    reached? = details[:rate_limit_reached_type] not in [nil, ""]
    state = state_for(valid_windows, missing_windows, malformed?, reached?, freshness)

    availability =
      if reached?, do: "refused", else: if(valid_windows > 0, do: "available", else: "unknown")

    %{
      provider: provider,
      state: state,
      availability: availability,
      confidence: confidence_for(state, valid_windows, freshness),
      source_event: source_event,
      observed_at: observed_at,
      freshness: freshness,
      windows: windows,
      details: details,
      reason: reason_for(state, valid_windows, missing_windows, malformed?, reached?)
    }
  end

  defp state_for(_valid, _missing, _malformed, true, _freshness), do: "refused"
  defp state_for(_valid, _missing, true, false, _freshness), do: "unknown"
  defp state_for(0, _missing, false, false, _freshness), do: "unknown"
  defp state_for(_valid, _missing, false, false, %{state: "stale"}), do: "degraded"
  defp state_for(_valid, missing, false, false, _freshness) when missing > 0, do: "degraded"
  defp state_for(_valid, _missing, false, false, _freshness), do: "observed"

  defp confidence_for("observed", _valid, %{state: "fresh"}), do: "high"
  defp confidence_for("refused", _valid, %{state: "fresh"}), do: "high"
  defp confidence_for("degraded", _valid, %{state: "fresh"}), do: "medium"
  defp confidence_for("degraded", _valid, _freshness), do: "low"
  defp confidence_for(_state, _valid, _freshness), do: "none"

  defp reason_for("observed", _valid, _missing, _malformed, _reached), do: nil

  defp reason_for("refused", _valid, _missing, _malformed, _reached),
    do: "provider_reported_rate_limit_reached"

  defp reason_for("unknown", _valid, _missing, true, _reached), do: "malformed_window_value"
  defp reason_for("unknown", 0, _missing, _malformed, _reached), do: "no_valid_windows"

  defp reason_for("degraded", _valid, _missing, _malformed, _reached),
    do: "partial_or_stale_observation"

  defp reason_for(_state, _valid, _missing, _malformed, _reached), do: "unavailable_observation"

  defp freshness(nil, _now, max_age),
    do: %{state: "unknown", age_seconds: nil, max_age_seconds: max_age}

  defp freshness(observed_at, now, max_age) when is_binary(observed_at) do
    case DateTime.from_iso8601(observed_at) do
      {:ok, observed, _offset} ->
        age = max(DateTime.diff(now, observed, :second), 0)

        %{
          state: if(age <= max_age, do: "fresh", else: "stale"),
          age_seconds: age,
          max_age_seconds: max_age
        }

      _ ->
        %{state: "unknown", age_seconds: nil, max_age_seconds: max_age}
    end
  end

  defp freshness(_observed_at, _now, max_age),
    do: %{state: "unknown", age_seconds: nil, max_age_seconds: max_age}

  defp required_percentage(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) and value >= 0 and value <= 100 -> {:ok, value}
      {:ok, value} when is_float(value) and value >= 0 and value <= 100 -> {:ok, value}
      :error -> {:error, "missing_#{key}"}
      _ -> {:error, "malformed_#{key}"}
    end
  end

  defp optional_integer(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_integer(value) -> {:ok, value}
      _ -> {:error, "malformed_#{key}"}
    end
  end

  defp required_integer(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      :error -> {:error, "missing_#{key}"}
      _ -> {:error, "malformed_#{key}"}
    end
  end

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  defp boolean_or_nil(value) when is_boolean(value), do: value
  defp boolean_or_nil(_value), do: nil

  defp claude_rate_limit_refusal?(payload) do
    Map.get(payload, "is_error") == true and
      Map.get(payload, "subtype") in ["rate_limit", "rate_limit_reached"]
  end

  defp reset_credit_count(%{"availableCount" => count}) when is_integer(count), do: count
  defp reset_credit_count(_reset_credits), do: nil

  defp reset_credit_detail_state(payload) do
    result = Map.get(payload, "result")

    if is_map(result) and Map.has_key?(result, "rateLimitResetCredits") do
      reset_credit_detail_state_value(Map.get(result, "rateLimitResetCredits"))
    else
      "absent"
    end
  end

  defp reset_credit_detail_state_value(reset_credits) when is_map(reset_credits) do
    cond do
      not Map.has_key?(reset_credits, "credits") -> "absent"
      is_nil(reset_credits["credits"]) -> "unavailable"
      is_list(reset_credits["credits"]) and reset_credits["credits"] == [] -> "empty"
      is_list(reset_credits["credits"]) -> "present_redacted"
      true -> "unknown"
    end
  end

  defp reset_credit_detail_state_value(nil), do: "unavailable"
  defp reset_credit_detail_state_value(_reset_credits), do: "unknown"

  defp provider_name(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp provider_name(provider) when is_binary(provider), do: provider
  defp provider_name(_provider), do: "unknown"

  defp unknown(provider, reason, opts) do
    %{
      provider: provider_name(provider),
      state: "unknown",
      availability: "unknown",
      confidence: "none",
      source_event: "none",
      observed_at: option(opts, :observed_at),
      freshness: %{
        state: "unknown",
        age_seconds: nil,
        max_age_seconds: option(opts, :freshness_seconds, @default_freshness_seconds)
      },
      windows: %{},
      details: %{},
      reason: reason
    }
  end

  defp option(opts, key, default \\ nil)
  defp option(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
  defp option(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)
  defp option(_opts, _key, default), do: default

  defp normalize_reason(reason) when is_binary(reason) do
    if String.starts_with?(reason, "malformed_"), do: "malformed_window_value", else: reason
  end

  defp normalize_reason(reason), do: reason
end
