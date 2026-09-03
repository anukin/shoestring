defmodule Shoestring.Harness.Capacity do
  @moduledoc """
  Production capacity compatibility boundary and observation normalizer.

  This module serves as the primary public contract for future monitor
  implementations (`CodexMonitor`, `ClaudeMonitor`). It encapsulates:

  1. Compatibility checking seeded from the Gate 0A support matrix
     (`Shoestring.Harness.Capacity.Registry`).
  2. Injectable CLI version discovery (`Shoestring.Harness.Capacity.CommandRunner`).
  3. Observation normalization producing valid `Shoestring.Harness.CapacitySnapshot`
     v2 structures while tolerating additive unknown provider fields and failing
     closed on missing/malformed semantic fields without fabricating zero usage.
  4. Safe preservation of last-known observations upon parse or protocol failures.
  """

  alias Shoestring.Harness.CapacitySnapshot
  alias Shoestring.Harness.Capacity.Registry
  alias Shoestring.Harness.Security

  @default_freshness_seconds 300
  @max_reason_length 300

  @doc "Returns all registered compatibility entries from the Gate 0A matrix."
  @spec registry_entries() :: [Registry.Entry.t()]
  def registry_entries, do: Registry.entries()

  @doc "Looks up a registry entry by provider and mode."
  @spec lookup_registry(atom() | String.t(), atom() | String.t()) ::
          {:ok, Registry.Entry.t()} | {:error, :unsupported_provider | :unsupported_mode}
  def lookup_registry(provider, mode), do: Registry.lookup(provider, mode)

  @doc "Checks if a given version is tested for a registry entry."
  @spec tested_version?(Registry.Entry.t(), String.t() | nil) :: boolean()
  def tested_version?(entry, version), do: Registry.tested_version?(entry, version)

  @doc """
  Discovers installed provider CLI version using an injectable command runner.

  ## Options

    * `:runner` - module implementing `CommandRunner`, or a 1/2/3-arity function,
      or a map `%{command => version_output}`. Defaults to `Shoestring.Harness.Capacity.SystemCommandRunner`.
    * `:command` - binary command name/path override (defaults to `"codex"` or `"claude"`).
    * `:timeout` - execution timeout in milliseconds (defaults to 5000).
  """
  @spec discover_version(atom() | String.t(), keyword()) ::
          {:ok, %{raw: String.t(), version: String.t()}}
          | {:error,
             :not_found
             | {:command_failed, non_neg_integer(), String.t()}
             | :timeout
             | :invalid_runner
             | term()}
  def discover_version(provider, opts \\ []) do
    with {:ok, provider_atom} <- Registry.normalize_provider(provider) do
      runner = Keyword.get(opts, :runner, Shoestring.Harness.Capacity.SystemCommandRunner)
      default_cmd = if provider_atom == :codex, do: "codex", else: "claude"
      command_name = Keyword.get(opts, :command, default_cmd)
      timeout = Keyword.get(opts, :timeout, 5_000)

      parent = self()
      ref = make_ref()

      {pid, mon} =
        spawn_monitor(fn ->
          result =
            try do
              execute_version_command(runner, command_name, opts)
            rescue
              _ -> {:error, :invalid_runner}
            catch
              :exit, _ -> {:error, :invalid_runner}
              :throw, _ -> {:error, :invalid_runner}
              _, _ -> {:error, :invalid_runner}
            end

          send(parent, {ref, result})
        end)

      receive do
        {^ref, result} ->
          Process.demonitor(mon, [:flush])
          result

        {:DOWN, ^mon, :process, ^pid, _reason} ->
          {:error, :invalid_runner}
      after
        timeout ->
          Process.demonitor(mon, [:flush])
          Process.exit(pid, :kill)

          receive do
            {:DOWN, ^mon, :process, ^pid, _} -> :ok
          after
            0 -> :ok
          end

          {:error, :timeout}
      end
    end
  end

  @doc """
  Evaluates compatibility for a provider, observation mode, and version.

  Returns a map detailing the resolved provider, mode, support tier,
  compatibility state (`:compatible`, `:degraded`, or `:incompatible`),
  and any bounded reason string.
  """
  @spec compatibility(atom() | String.t(), atom() | String.t(), String.t() | keyword() | nil) ::
          %{
            provider: atom(),
            invocation_mode: atom() | nil,
            support_tier: :proactive | :conservative_partial | :reactive_only | :unsupported,
            compatibility_state: :compatible | :degraded | :incompatible,
            version: String.t() | nil,
            reason: String.t() | nil
          }
  def compatibility(provider, mode, version_or_opts \\ nil)

  def compatibility(provider, mode, opts) when is_list(opts) do
    version = Keyword.get(opts, :version)
    compatibility(provider, mode, version)
  end

  def compatibility(provider, mode, version) do
    case Registry.lookup(provider, mode) do
      {:error, :unsupported_provider} ->
        %{
          provider: :unknown,
          invocation_mode: nil,
          support_tier: :unsupported,
          compatibility_state: :incompatible,
          version: Registry.normalize_version(version),
          reason: bound_reason("unsupported_provider: #{inspect(provider)}")
        }

      {:error, :unsupported_mode} ->
        provider_atom =
          case Registry.normalize_provider(provider) do
            {:ok, p} -> p
            _ -> :unknown
          end

        %{
          provider: provider_atom,
          invocation_mode: nil,
          support_tier: :unsupported,
          compatibility_state: :incompatible,
          version: Registry.normalize_version(version),
          reason: bound_reason("unsupported_mode: #{inspect(mode)}")
        }

      {:ok, %Registry.Entry{compatibility_outcome: :incompatible} = entry} ->
        %{
          provider: entry.provider,
          invocation_mode: entry.invocation_mode,
          support_tier: entry.supported_tier,
          compatibility_state: :incompatible,
          version: Registry.normalize_version(version),
          reason: bound_reason("unsupported_mode: #{entry.description}")
        }

      {:ok, %Registry.Entry{} = entry} ->
        normalized_version = Registry.normalize_version(version)

        cond do
          is_nil(normalized_version) ->
            reason =
              if is_nil(version) do
                "untested_cli_version: unknown"
              else
                bound_reason("untested_cli_version: #{inspect(version)}")
              end

            %{
              provider: entry.provider,
              invocation_mode: entry.invocation_mode,
              support_tier: entry.supported_tier,
              compatibility_state: :degraded,
              version: nil,
              reason: reason
            }

          Registry.tested_version?(entry, normalized_version) ->
            %{
              provider: entry.provider,
              invocation_mode: entry.invocation_mode,
              support_tier: entry.supported_tier,
              compatibility_state: :compatible,
              version: normalized_version,
              reason: nil
            }

          true ->
            %{
              provider: entry.provider,
              invocation_mode: entry.invocation_mode,
              support_tier: entry.supported_tier,
              compatibility_state: :degraded,
              version: normalized_version,
              reason: bound_reason("untested_cli_version: #{normalized_version}")
            }
        end
    end
  end

  @doc """
  Normalizes a provider payload into a versioned `Shoestring.Harness.CapacitySnapshot`.

  ## Options

    * `:version` - CLI version string.
    * `:now` - evaluation timestamp (`DateTime.t()`). Defaults to `DateTime.utc_now()`.
    * `:captured_at` - observation timestamp override.
    * `:snapshot_id` - UUID string override.
    * `:source_event` - source event atom override.
    * `:adapter_id` - string adapter identifier.
    * `:scope` - scope string (defaults to `"subscription"`).
    * `:freshness_seconds` - max freshness age in seconds (defaults to 300).
    * `:last_known_snapshot` - `%CapacitySnapshot{}` to preserve when parsing fails.
  """
  @spec normalize(atom() | String.t(), atom() | String.t(), map() | binary(), keyword()) ::
          {:ok, CapacitySnapshot.t()}
          | {:error,
             :payload_too_large
             | :payload_too_deep
             | :contains_secrets_or_forbidden_content
             | term()}
  def normalize(provider, mode, raw_observation, opts \\ [])

  def normalize(provider, mode, raw_observation, opts) when is_binary(raw_observation) do
    case Jason.decode(raw_observation) do
      {:ok, decoded} ->
        normalize(provider, mode, decoded, opts)

      {:error, _reason} ->
        handle_parse_failure(
          provider,
          mode,
          "malformed_json",
          opts
        )
    end
  end

  def normalize(provider, mode, raw_observation, opts) when is_map(raw_observation) do
    case Security.validate_observation(raw_observation) do
      :ok ->
        do_normalize(provider, mode, raw_observation, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def normalize(provider, mode, _invalid_observation, opts) do
    handle_parse_failure(
      provider,
      mode,
      "malformed_payload",
      opts
    )
  end

  @doc """
  Preserves a last-known observation with degraded/stale status on parse error,
  ensuring known capacity is never overwritten with fabricated zero usage.
  """
  @spec preserve_last_known(CapacitySnapshot.t(), String.t(), keyword()) ::
          {:ok, CapacitySnapshot.t()} | {:error, Ecto.Changeset.t()}
  def preserve_last_known(%CapacitySnapshot{} = last_known, reason, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    snapshot_id = Keyword.get(opts, :snapshot_id) || Ecto.UUID.generate()
    bounded_reason = bound_reason("parse_error: #{reason}; preserving last-known observation")

    # If the last-known snapshot had observed windows, mark degraded so windows remain preserved
    capacity_state =
      if Enum.any?(last_known.windows, &(&1.state == :observed)),
        do: :degraded,
        else: :unknown

    confidence = if capacity_state == :degraded, do: :low, else: :none

    # For unknown capacity state, windows cannot be :observed
    windows =
      if capacity_state == :unknown do
        Enum.map(last_known.windows, fn w ->
          %{kind: w.kind, state: :unknown, reason: bounded_reason}
        end)
      else
        last_known.windows
      end

    observed_at = if capacity_state == :degraded, do: last_known.observed_at, else: nil

    CapacitySnapshot.new(
      %{
        version: 2,
        snapshot_id: snapshot_id,
        capacity_state: capacity_state,
        windows: windows,
        observed_at: observed_at,
        freshness: last_known.freshness,
        source: last_known.source,
        scope: last_known.scope,
        confidence: confidence,
        support_tier: last_known.support_tier,
        compatibility_state: :degraded,
        reason: bounded_reason,
        extensions: last_known.extensions
      },
      now: now
    )
  end

  # --- Safety Scanner ---

  @doc """
  Checks if an untrusted observation is safe, bounded, and contains no secrets
  or forbidden credential keys.
  """
  @spec safe_observation?(term()) :: boolean()
  def safe_observation?(term), do: Security.safe_observation?(term)

  @doc """
  Validates an observation against resource bounds and security policies.
  """
  @spec validate_observation(term()) ::
          :ok
          | {:error,
             :payload_too_large | :payload_too_deep | :contains_secrets_or_forbidden_content}
  def validate_observation(term), do: Security.validate_observation(term)

  # --- Internal Normalization ---

  defp do_normalize(provider, mode, observation, opts) do
    payload = Map.get(observation, "payload", observation)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    freshness_seconds = Keyword.get(opts, :freshness_seconds, @default_freshness_seconds)

    version =
      Keyword.get(opts, :version) ||
        payload_version(payload)

    compat = compatibility(provider, mode, version)
    captured_at = resolve_captured_at(observation, opts)

    cond do
      compat.compatibility_state == :incompatible ->
        build_incompatible_snapshot(
          compat,
          provider,
          mode,
          captured_at,
          now,
          freshness_seconds,
          opts
        )

      not is_map(payload) ->
        cond do
          compat.provider == :codex ->
            handle_codex_parse_failure(
              "malformed_payload",
              compat,
              captured_at,
              now,
              freshness_seconds,
              opts
            )

          compat.provider == :claude ->
            handle_claude_parse_failure(
              "malformed_payload",
              compat,
              captured_at,
              now,
              freshness_seconds,
              opts
            )

          true ->
            handle_parse_failure(provider, mode, "malformed_payload", opts)
        end

      compat.provider == :codex ->
        normalize_codex(payload, compat, captured_at, now, freshness_seconds, opts)

      compat.provider == :claude ->
        normalize_claude(payload, compat, captured_at, now, freshness_seconds, opts)

      true ->
        handle_parse_failure(provider, mode, "unsupported_provider", opts)
    end
  end

  defp normalize_codex(payload, compat, captured_at, now, freshness_seconds, opts) do
    source_event =
      Keyword.get(opts, :source_event) ||
        if Map.get(payload, "method") == "account/rateLimits/updated",
          do: :update_notification,
          else: :explicit_read

    case extract_codex_rate_limits(payload) do
      {:refusal, refusal_type} ->
        build_refusal_snapshot(
          compat,
          :codex,
          "provider_reported_rate_limit_reached",
          ["primary", "secondary"],
          source_event,
          captured_at,
          now,
          freshness_seconds,
          opts,
          %{"codex:rate_limit_reached_type" => to_string(refusal_type)}
        )

      {:ok, rate_limits} ->
        parse_codex_rate_limits(
          rate_limits,
          payload,
          compat,
          source_event,
          captured_at,
          now,
          freshness_seconds,
          opts
        )

      {:error, reason} ->
        handle_codex_parse_failure(reason, compat, captured_at, now, freshness_seconds, opts)
    end
  end

  defp extract_codex_rate_limits(payload) do
    rate_limits =
      case dig(payload, ["result", "rateLimits"]) do
        {:ok, val} when not is_nil(val) ->
          val

        _ ->
          case dig(payload, ["params", "rateLimits"]) do
            {:ok, val} when not is_nil(val) -> val
            _ -> Map.get(payload, "rateLimits")
          end
      end

    cond do
      is_nil(rate_limits) ->
        {:error, "missing_rate_limits"}

      not is_map(rate_limits) ->
        {:error, "malformed_rate_limits"}

      codex_refusal?(rate_limits) ->
        {:refusal, Map.get(rate_limits, "rateLimitReachedType")}

      true ->
        {:ok, rate_limits}
    end
  end

  defp codex_refusal?(rate_limits) do
    case Map.get(rate_limits, "rateLimitReachedType") do
      nil -> false
      val when is_binary(val) and val != "" -> true
      _ -> false
    end
  end

  defp parse_codex_rate_limits(
         rate_limits,
         payload,
         compat,
         source_event,
         captured_at,
         now,
         freshness_seconds,
         opts
       ) do
    primary_res =
      parse_window("primary", Map.get(rate_limits, "primary"), "usedPercent", "resetsAt")

    secondary_res =
      parse_window("secondary", Map.get(rate_limits, "secondary"), "usedPercent", "resetsAt")

    extensions = extract_codex_extensions(rate_limits, payload)

    cond do
      match?({:malformed, _}, primary_res) or match?({:malformed, _}, secondary_res) ->
        handle_codex_parse_failure(
          "malformed_window_value",
          compat,
          captured_at,
          now,
          freshness_seconds,
          opts
        )

      primary_res == :absent and secondary_res == :absent ->
        handle_codex_parse_failure(
          "no_valid_windows",
          compat,
          captured_at,
          now,
          freshness_seconds,
          opts
        )

      true ->
        build_codex_snapshot(
          primary_res,
          secondary_res,
          compat,
          source_event,
          captured_at,
          now,
          freshness_seconds,
          extensions,
          opts
        )
    end
  end

  defp build_codex_snapshot(
         primary_res,
         secondary_res,
         compat,
         source_event,
         captured_at,
         now,
         freshness_seconds,
         extensions,
         opts
       ) do
    case validate_timestamp(captured_at, now, freshness_seconds) do
      {:invalid, ts_reason} ->
        windows = [
          window_unknown("primary", ts_reason),
          window_unknown("secondary", ts_reason)
        ]

        build_unknown_snapshot(
          compat,
          windows,
          ts_reason,
          now,
          freshness_seconds,
          source_event,
          opts,
          extensions
        )

      {:valid, freshness_state} ->
        windows = [
          normalize_window_result("primary", primary_res, "missing_window: primary"),
          normalize_window_result("secondary", secondary_res, "missing_window: secondary")
        ]

        all_observed? = primary_res != :absent and secondary_res != :absent

        partial_reason =
          cond do
            secondary_res == :absent and primary_res == :absent -> "no_valid_windows"
            secondary_res == :absent -> "missing_window: secondary"
            primary_res == :absent -> "missing_window: primary"
            true -> nil
          end

        stale_reason = if freshness_state == :stale, do: "stale_observation", else: nil

        reasons =
          Enum.reject([compat.reason, stale_reason, partial_reason], &is_nil/1)

        combined_reason =
          case reasons do
            [] -> nil
            list -> bound_reason(Enum.join(list, "; "))
          end

        confidence =
          cond do
            freshness_state == :stale -> :low
            not all_observed? or compat.compatibility_state == :degraded -> :medium
            true -> :high
          end

        capacity_state =
          if freshness_state == :stale or not all_observed? or
               compat.compatibility_state == :degraded do
            :degraded
          else
            :observed
          end

        build_snapshot_struct(
          capacity_state,
          compat.support_tier,
          compat.compatibility_state,
          windows,
          captured_at,
          freshness_seconds,
          compat.provider,
          compat.invocation_mode,
          source_event,
          confidence,
          combined_reason,
          extensions,
          now,
          opts
        )
    end
  end

  defp normalize_claude(payload, compat, captured_at, now, freshness_seconds, opts) do
    source_event = Keyword.get(opts, :source_event, :status_line_input)
    rate_limits = Map.get(payload, "rate_limits")

    cond do
      claude_refusal?(payload) ->
        build_refusal_snapshot(
          compat,
          :claude,
          "cli_reported_rate_limit_refusal_without_capacity_snapshot",
          ["five_hour", "seven_day"],
          source_event,
          captured_at,
          now,
          freshness_seconds,
          opts,
          %{}
        )

      claude_provider_error?(payload) ->
        build_unknown_snapshot(
          compat,
          [],
          "provider_error",
          now,
          freshness_seconds,
          :headless_result_error,
          opts,
          %{}
        )

      is_nil(rate_limits) ->
        build_unknown_snapshot(
          compat,
          [],
          "rate_limits_absent_before_first_response_or_unsupported_subscription",
          now,
          freshness_seconds,
          source_event,
          opts,
          %{}
        )

      not is_map(rate_limits) ->
        handle_claude_parse_failure(
          "malformed_rate_limits",
          compat,
          captured_at,
          now,
          freshness_seconds,
          opts
        )

      true ->
        parse_claude_rate_limits(
          rate_limits,
          compat,
          source_event,
          captured_at,
          now,
          freshness_seconds,
          opts
        )
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

  defp parse_claude_rate_limits(
         rate_limits,
         compat,
         source_event,
         captured_at,
         now,
         freshness_seconds,
         opts
       ) do
    five_hour_res =
      parse_window("five_hour", Map.get(rate_limits, "five_hour"), "used_percentage", "resets_at")

    seven_day_res =
      parse_window("seven_day", Map.get(rate_limits, "seven_day"), "used_percentage", "resets_at")

    cond do
      match?({:malformed, _}, five_hour_res) or match?({:malformed, _}, seven_day_res) ->
        handle_claude_parse_failure(
          "malformed_window_value",
          compat,
          captured_at,
          now,
          freshness_seconds,
          opts
        )

      five_hour_res == :absent and seven_day_res == :absent ->
        handle_claude_parse_failure(
          "no_valid_windows",
          compat,
          captured_at,
          now,
          freshness_seconds,
          opts
        )

      true ->
        build_claude_snapshot(
          five_hour_res,
          seven_day_res,
          compat,
          source_event,
          captured_at,
          now,
          freshness_seconds,
          opts
        )
    end
  end

  defp build_claude_snapshot(
         five_hour_res,
         seven_day_res,
         compat,
         source_event,
         captured_at,
         now,
         freshness_seconds,
         opts
       ) do
    case validate_timestamp(captured_at, now, freshness_seconds) do
      {:invalid, ts_reason} ->
        windows = [
          window_unknown("five_hour", ts_reason),
          window_unknown("seven_day", ts_reason)
        ]

        build_unknown_snapshot(
          compat,
          windows,
          ts_reason,
          now,
          freshness_seconds,
          source_event,
          opts,
          %{}
        )

      {:valid, freshness_state} ->
        windows =
          Enum.reject(
            [
              if(five_hour_res != :absent,
                do: elem(five_hour_res, 1),
                else: window_unknown("five_hour", "absent_in_status_line")
              ),
              if(seven_day_res != :absent,
                do: elem(seven_day_res, 1),
                else: window_unknown("seven_day", "absent_in_status_line")
              )
            ],
            &is_nil/1
          )

        all_observed? = five_hour_res != :absent and seven_day_res != :absent

        partial_reason =
          if not all_observed?, do: "partial_window_observation", else: nil

        stale_reason = if freshness_state == :stale, do: "stale_observation", else: nil

        reasons =
          Enum.reject([compat.reason, stale_reason, partial_reason], &is_nil/1)

        combined_reason =
          case reasons do
            [] -> "conservative_partial_observation"
            list -> bound_reason(Enum.join(list, "; "))
          end

        confidence = if freshness_state == :stale, do: :low, else: :medium

        build_snapshot_struct(
          :degraded,
          compat.support_tier,
          compat.compatibility_state,
          windows,
          captured_at,
          freshness_seconds,
          compat.provider,
          compat.invocation_mode,
          source_event,
          confidence,
          combined_reason,
          %{},
          now,
          opts
        )
    end
  end

  # --- Window & Field Parsing ---

  defp parse_window(_kind, nil, _used_key, _reset_key), do: :absent

  defp parse_window(kind, window_map, used_key, reset_key) when is_map(window_map) do
    used = Map.get(window_map, used_key)
    reset = Map.get(window_map, reset_key)

    cond do
      is_number(used) and used >= 0 and used <= 100 ->
        reset_at = parse_reset_timestamp(reset)
        {:ok, %{kind: kind, state: :observed, used_percent: used, reset_at: reset_at}}

      true ->
        {:malformed, "malformed_window_value"}
    end
  end

  defp parse_window(_kind, _other, _used_key, _reset_key),
    do: {:malformed, "malformed_window_value"}

  defp normalize_window_result(_kind, {:ok, window}, _missing_reason), do: window

  defp normalize_window_result(kind, :absent, missing_reason),
    do: window_unknown(kind, missing_reason)

  defp window_unknown(kind, reason) do
    %{kind: kind, state: :unknown, reason: bound_reason(reason)}
  end

  defp parse_reset_timestamp(nil), do: nil

  defp parse_reset_timestamp(epoch) when is_integer(epoch) and epoch > 0 do
    DateTime.from_unix(epoch)
    |> case do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp parse_reset_timestamp(%DateTime{} = dt), do: dt

  defp parse_reset_timestamp(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_reset_timestamp(_), do: nil

  # --- Timestamps and Freshness ---

  defp resolve_captured_at(observation, opts) do
    case Keyword.get(opts, :captured_at) || Keyword.get(opts, :observed_at) do
      %DateTime{} = dt ->
        dt

      iso when is_binary(iso) ->
        case DateTime.from_iso8601(iso) do
          {:ok, dt, _} -> dt
          _ -> nil
        end

      nil ->
        str = Map.get(observation, "captured_at") || Map.get(observation, "observed_at")

        if is_binary(str) do
          case DateTime.from_iso8601(str) do
            {:ok, dt, _} -> dt
            _ -> nil
          end
        else
          nil
        end
    end
  end

  defp validate_timestamp(nil, _now, _max_age),
    do: {:invalid, "missing_or_invalid_observation_timestamp"}

  defp validate_timestamp(%DateTime{} = captured_at, %DateTime{} = now, max_age) do
    cond do
      DateTime.compare(captured_at, now) == :gt ->
        {:invalid, "missing_or_invalid_observation_timestamp"}

      DateTime.diff(now, captured_at, :second) > max_age ->
        {:valid, :stale}

      true ->
        {:valid, :fresh}
    end
  end

  # --- Snapshot Builders ---

  defp build_snapshot_struct(
         capacity_state,
         support_tier,
         compatibility_state,
         windows,
         observed_at,
         freshness_seconds,
         provider,
         mode,
         source_event,
         confidence,
         reason,
         extensions,
         now,
         opts
       ) do
    snapshot_id = Keyword.get(opts, :snapshot_id) || Ecto.UUID.generate()
    adapter_id = Keyword.get(opts, :adapter_id, "#{provider}_#{mode}")
    scope = Keyword.get(opts, :scope, "subscription")

    source_provider = to_string(compat_provider_string(provider))
    source_mode = to_string(compat_mode_string(mode))

    CapacitySnapshot.new(
      %{
        version: 2,
        snapshot_id: snapshot_id,
        capacity_state: capacity_state,
        windows: windows,
        observed_at: observed_at,
        freshness: %{max_age_seconds: freshness_seconds},
        source: %{
          adapter_id: adapter_id,
          provider_id: source_provider,
          invocation_mode: source_mode,
          event: source_event
        },
        scope: scope,
        confidence: confidence,
        support_tier: support_tier,
        compatibility_state: compatibility_state,
        reason: bound_reason(reason),
        extensions: extensions
      },
      now: now
    )
  end

  defp compat_provider_string(nil), do: "unknown"
  defp compat_provider_string(:unknown), do: "unknown"
  defp compat_provider_string(val), do: to_string(val)

  defp compat_mode_string(nil), do: "unknown"
  defp compat_mode_string(val), do: to_string(val)

  defp build_unknown_snapshot(
         compat,
         windows,
         reason,
         now,
         freshness_seconds,
         source_event,
         opts,
         extensions
       ) do
    build_snapshot_struct(
      :unknown,
      compat.support_tier,
      compat.compatibility_state,
      windows,
      nil,
      freshness_seconds,
      compat.provider,
      compat.invocation_mode,
      source_event,
      :none,
      reason,
      extensions,
      now,
      opts
    )
  end

  defp build_incompatible_snapshot(
         compat,
         provider,
         mode,
         _captured_at,
         now,
         freshness_seconds,
         opts
       ) do
    build_snapshot_struct(
      :unknown,
      compat.support_tier,
      :incompatible,
      [],
      nil,
      freshness_seconds,
      compat.provider || provider,
      compat.invocation_mode || mode,
      :none,
      :none,
      compat.reason,
      %{},
      now,
      opts
    )
  end

  defp build_refusal_snapshot(
         compat,
         provider,
         reason,
         window_kinds,
         source_event,
         _captured_at,
         now,
         freshness_seconds,
         opts,
         extensions
       ) do
    windows =
      Enum.map(window_kinds, fn kind ->
        window_unknown(kind, reason)
      end)

    build_snapshot_struct(
      :refused,
      compat.support_tier,
      compat.compatibility_state,
      windows,
      nil,
      freshness_seconds,
      provider,
      compat.invocation_mode,
      source_event,
      :low,
      reason,
      extensions,
      now,
      opts
    )
  end

  defp handle_parse_failure(provider, mode, reason, opts) do
    case Keyword.get(opts, :last_known_snapshot) do
      %CapacitySnapshot{} = last_known ->
        preserve_last_known(last_known, reason, opts)

      _ ->
        now = Keyword.get(opts, :now, DateTime.utc_now())
        freshness_seconds = Keyword.get(opts, :freshness_seconds, @default_freshness_seconds)
        compat = compatibility(provider, mode, Keyword.get(opts, :version))

        build_unknown_snapshot(
          compat,
          [],
          reason,
          now,
          freshness_seconds,
          :none,
          opts,
          %{}
        )
    end
  end

  defp handle_codex_parse_failure(reason, compat, _captured_at, now, freshness_seconds, opts) do
    case Keyword.get(opts, :last_known_snapshot) do
      %CapacitySnapshot{} = last_known ->
        preserve_last_known(last_known, reason, opts)

      _ ->
        windows = [
          window_unknown("primary", reason),
          window_unknown("secondary", reason)
        ]

        build_unknown_snapshot(
          compat,
          windows,
          reason,
          now,
          freshness_seconds,
          :explicit_read,
          opts,
          %{}
        )
    end
  end

  defp handle_claude_parse_failure(reason, compat, _captured_at, now, freshness_seconds, opts) do
    case Keyword.get(opts, :last_known_snapshot) do
      %CapacitySnapshot{} = last_known ->
        preserve_last_known(last_known, reason, opts)

      _ ->
        windows = [
          window_unknown("five_hour", reason),
          window_unknown("seven_day", reason)
        ]

        build_unknown_snapshot(
          compat,
          windows,
          reason,
          now,
          freshness_seconds,
          :status_line_input,
          opts,
          %{}
        )
    end
  end

  # --- Extensions & Helpers ---

  defp extract_codex_extensions(rate_limits, payload) do
    ext = %{}

    ext =
      case Map.get(rate_limits, "planType") do
        plan when is_binary(plan) -> Map.put(ext, "codex:plan_type", plan)
        _ -> ext
      end

    ext =
      case dig(payload, ["result", "rateLimitResetCredits", "availableCount"]) do
        {:ok, count} when is_integer(count) -> Map.put(ext, "codex:reset_credit_count", count)
        _ -> ext
      end

    ext
  end

  defp payload_version(payload) when is_map(payload) do
    Map.get(payload, "version") || dig_val(payload, ["result", "version"])
  end

  defp payload_version(_), do: nil

  defp dig(container, keys) do
    Enum.reduce_while(keys, {:ok, container}, fn key, {:ok, acc} ->
      cond do
        is_map(acc) -> {:cont, {:ok, Map.get(acc, key)}}
        is_nil(acc) -> {:cont, {:ok, nil}}
        true -> {:halt, :error}
      end
    end)
  end

  defp dig_val(container, keys) do
    case dig(container, keys) do
      {:ok, val} -> val
      _ -> nil
    end
  end

  defp bound_reason(nil), do: nil

  defp bound_reason(reason) when is_binary(reason) do
    String.slice(reason, 0, @max_reason_length)
  end

  # --- Command Execution Boundary ---

  defp execute_version_command(runner, command_name, opts) do
    cond do
      is_atom(runner) ->
        try do
          if Code.ensure_loaded?(runner) and
               function_exported?(runner, :find_executable, 1) and
               (function_exported?(runner, :cmd, 3) or function_exported?(runner, :cmd, 2)) do
            case runner.find_executable(command_name) do
              nil ->
                {:error, :not_found}

              exec_path when is_binary(exec_path) ->
                run_cmd(runner, exec_path, ["--version"], opts)

              _other ->
                {:error, :invalid_runner}
            end
          else
            {:error, :invalid_runner}
          end
        rescue
          _ -> {:error, :invalid_runner}
        catch
          :exit, _ -> {:error, :invalid_runner}
          :throw, _ -> {:error, :invalid_runner}
          _, _ -> {:error, :invalid_runner}
        end

      is_function(runner, 3) ->
        try do
          case runner.(command_name, ["--version"], opts) do
            {output, status} when is_binary(output) and is_integer(status) ->
              parse_cmd_output(output, status)

            _other ->
              {:error, :invalid_runner}
          end
        rescue
          _ -> {:error, :invalid_runner}
        catch
          :exit, _ -> {:error, :invalid_runner}
          :throw, _ -> {:error, :invalid_runner}
          _, _ -> {:error, :invalid_runner}
        end

      is_function(runner, 2) ->
        try do
          case runner.(command_name, ["--version"]) do
            {output, status} when is_binary(output) and is_integer(status) ->
              parse_cmd_output(output, status)

            _other ->
              {:error, :invalid_runner}
          end
        rescue
          _ -> {:error, :invalid_runner}
        catch
          :exit, _ -> {:error, :invalid_runner}
          :throw, _ -> {:error, :invalid_runner}
          _, _ -> {:error, :invalid_runner}
        end

      is_function(runner, 1) ->
        try do
          case runner.(command_name) do
            {output, status} when is_binary(output) and is_integer(status) ->
              parse_cmd_output(output, status)

            _other ->
              {:error, :invalid_runner}
          end
        rescue
          _ -> {:error, :invalid_runner}
        catch
          :exit, _ -> {:error, :invalid_runner}
          :throw, _ -> {:error, :invalid_runner}
          _, _ -> {:error, :invalid_runner}
        end

      is_map(runner) ->
        try do
          case Map.get(runner, command_name) do
            nil ->
              {:error, :not_found}

            {output, status} when is_binary(output) and is_integer(status) ->
              parse_cmd_output(output, status)

            output when is_binary(output) ->
              parse_cmd_output(output, 0)

            _other ->
              {:error, :invalid_runner}
          end
        rescue
          _ -> {:error, :invalid_runner}
        catch
          :exit, _ -> {:error, :invalid_runner}
          :throw, _ -> {:error, :invalid_runner}
          _, _ -> {:error, :invalid_runner}
        end

      true ->
        {:error, :invalid_runner}
    end
  end

  defp run_cmd(runner, exec_path, args, opts) do
    cmd_opts = Keyword.take(opts, [:stderr_to_stdout])

    try do
      {output, status} =
        if function_exported?(runner, :cmd, 3) do
          runner.cmd(exec_path, args, cmd_opts)
        else
          runner.cmd(exec_path, args)
        end

      if is_binary(output) and is_integer(status) do
        parse_cmd_output(output, status)
      else
        {:error, :invalid_runner}
      end
    rescue
      _ -> {:error, :invalid_runner}
    catch
      :exit, _ -> {:error, :invalid_runner}
      :throw, _ -> {:error, :invalid_runner}
      _, _ -> {:error, :invalid_runner}
    end
  end

  defp parse_cmd_output(output, 0) do
    bounded_output = String.slice(output, 0, 1024)

    raw =
      bounded_output
      |> String.trim()
      |> String.split(~r/\r?\n/)
      |> List.first() || ""

    bounded_raw =
      raw
      |> Security.redact()
      |> String.slice(0, 200)

    version = Registry.normalize_version(raw)
    {:ok, %{raw: bounded_raw, version: version}}
  end

  defp parse_cmd_output(output, exit_status) do
    snippet =
      output
      |> String.slice(0, 1024)
      |> Security.redact()
      |> String.trim()
      |> String.slice(0, 200)

    {:error, {:command_failed, exit_status, snippet}}
  end
end
