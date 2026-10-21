defmodule Shoestring.Diagnostics.Bundle do
  @moduledoc "Versioned diagnostic projection. Free text and original identities never cross this boundary."
  alias Shoestring.Cobbler.PlanContract
  alias Shoestring.Trajectory.EventRegistry

  @max_events 200
  @max_source_bytes 8 * 1024 * 1024
  @max_bytes 512 * 1024
  @registered EventRegistry.registered_types()
  @types Enum.uniq(Enum.map(@registered, &elem(&1, 0)))
  @providers ~w(claude codex fake claude_headless_stream_json codex_app_server_stdio)
  @tiers ~w(proactive reactive_only conservative_partial unsupported supported partial)
  @compatibility ~w(compatible degraded incompatible unknown)
  @reasons ~w(automatic_admission_eligible unsupported_capability incompatible_cli unsupported_tier
    scope_mismatch snapshot_provider_mismatch scope_occupied unknown_capacity future_observation
    stale_observation degraded_compatibility capacity_state_unknown capacity_state_degraded
    support_tier_reactive_only support_tier_conservative_partial confidence_low confidence_medium
    confidence_none unknown_window_five_hour missing_window_five_hour unknown_window_weekly missing_window_weekly
    hard_quota_refusal_deferred hard_quota_refusal_delayed past_reset_delayed_recheck
    reserve_breach_five_hour reserve_breach_weekly no_observation no_observation_for_provider admission_unavailable)
  @reasons @reasons ++
             Enum.map(@reasons, &("confirmed_" <> &1)) ++
             Enum.map(
               ~w(unattributed provider_mismatch scope_mismatch invalid_intent future_confirmation stale_confirmation),
               &("confirmation_invalid_" <> &1)
             )
  @exclusions ~w(credentials auth_files account_identifiers original_event_identifiers filesystem_paths
    source_code prompts hidden_reasoning terminal_logs gate_output free_text unlisted_configuration_values)

  def max_events, do: @max_events
  def max_source_bytes, do: @max_source_bytes
  def max_bytes, do: @max_bytes

  @doc "Build deterministic bytes from already selected events and trusted runtime metadata."
  def build(events, metadata, total) when is_list(events) and is_map(metadata) do
    cond do
      length(events) > @max_events ->
        {:error, :diagnostic_event_limit}

      not is_integer(total) or total < length(events) ->
        {:error, :invalid_diagnostic_selection}

      byte_size(Jason.encode!(Enum.map(events, &%{"type" => &1.type, "payload" => &1.payload}))) >
          @max_source_bytes ->
        {:error, :diagnostic_source_limit}

      true ->
        build_bounded(events, metadata, total)
    end
  end

  def build(_, _, _), do: {:error, :invalid_diagnostic_selection}

  def encode(bundle), do: PlanContract.canonical_json(bundle)
  def digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  def preview(bundle) do
    bytes = encode(bundle)

    %{
      "confirmation_sha256" => digest(bytes),
      "bytes" => byte_size(bytes),
      "manifest" => %{
        "format" => "shoestring-diagnostics",
        "version" => 1,
        "sections" => ~w(runtime configuration health compatibility_fixtures events),
        "selected_events" => length(bundle["events"]),
        "omitted_events" => bundle["selection"]["omitted_events"],
        "excluded" => @exclusions,
        "identity_policy" => "bundle_local_aliases",
        "time_policy" => "relative_milliseconds_only",
        "upload" => "none"
      },
      "bundle" => bundle
    }
  end

  defp build_bounded(events, metadata, total) do
    events = Enum.sort_by(events, &{time(&1.occurred_at), &1.goal_id, &1.sequence, &1.id})
    goals = aliases(events, & &1.goal_id, "goal")
    runs = aliases(events, & &1.run_id, "run")

    origin =
      events |> Enum.map(&time(&1.occurred_at)) |> Enum.reject(&is_nil/1) |> Enum.min(fn -> 0 end)

    bundle = %{
      "format" => "shoestring-diagnostics",
      "version" => 1,
      "runtime" => runtime(object(metadata["runtime"])),
      "configuration" => configuration(object(metadata["configuration"])),
      "health" => health(object(metadata["health"])),
      "compatibility_fixtures" => fixtures(object(metadata["compatibility_fixtures"])),
      "selection" => %{
        "selected_events" => length(events),
        "omitted_events" => total - length(events)
      },
      "events" =>
        events
        |> Enum.with_index(1)
        |> Enum.map(fn {event, index} ->
          %{
            "event" => "event-#{index}",
            "goal" => goals[event.goal_id],
            "run" => runs[event.run_id],
            "sequence" => integer(event.sequence),
            "relative_ms" => if(time(event.occurred_at), do: time(event.occurred_at) - origin),
            "type" => member(event.type, @types, "unregistered"),
            "schema_version" => integer(event.schema_version, 10_000),
            "schema_registered" => {event.type, event.schema_version} in @registered,
            "summary" => summarize(event.type, event.schema_version, event.payload)
          }
        end)
    }

    if byte_size(encode(bundle)) <= @max_bytes,
      do: {:ok, bundle},
      else: {:error, :diagnostic_export_limit}
  end

  # Only current, understood payloads get field projections; unknown versions
  # retain their envelope metadata without speculative interpretation.
  defp summarize(type, version, payload) when is_map(payload) do
    if {type, version} in @registered, do: summarize(type, payload), else: %{}
  end

  defp summarize(_, _, _), do: %{}

  defp summarize("capacity.snapshot_observed", payload) do
    source = object(payload["source"])
    extensions = object(payload["extensions"])

    %{
      "provider" => member(source["provider_id"], @providers),
      "adapter" => member(source["adapter_id"], @providers),
      "cli_version" => version(extensions["capacity:cli_version"]),
      "support_tier" => member(payload["support_tier"], @tiers),
      "compatibility" => member(payload["compatibility_state"], @compatibility),
      "capacity_state" => member(payload["capacity_state"], ~w(observed unknown degraded refused))
    }
  end

  defp summarize("admission.decided", payload) do
    candidate = object(payload["candidate"])
    reason = member(payload["reason_code"], @reasons)

    %{
      "result" => member(payload["result"], ~w(admit defer_until require_confirmation reject)),
      "reason" => reason,
      "explanation" => explanation(reason),
      "provider" => member(candidate["provider_id"], @providers),
      "support_tier" => member(candidate["support_tier"], @tiers),
      "compatibility" => member(candidate["compatibility_state"], @compatibility)
    }
  end

  defp summarize("cobbler.plan.admission.waiting", payload) do
    reason = member(payload["reason"], @reasons)

    %{
      "provider" => member(payload["provider_id"], @providers),
      "attempt" => integer(payload["attempt"]),
      "reason" => reason,
      "explanation" => explanation(reason)
    }
  end

  defp summarize("harness.event_recorded", payload) do
    error = object(payload["error"])

    %{
      "kind" =>
        member(payload["kind"], ~w(lifecycle output tool command artifact capacity error result)),
      "error_category" =>
        member(
          error["category"],
          Enum.map(Shoestring.Harness.Error.categories(), &Atom.to_string/1)
        )
    }
  end

  defp summarize("cobbler.plan.gate.completed", payload) do
    %{
      "result" => member(payload["result"], ~w(passed failed error)),
      "kind" => member(payload["kind"], Shoestring.Cobbler.GateSpec.kinds()),
      "duration_ms" => integer(payload["duration_ms"]),
      "exit_status" => integer(payload["exit_status"], 255),
      "required" => boolean(payload["required"])
    }
  end

  defp summarize(_, _), do: %{}

  defp runtime(input) do
    %{
      "shoestring" => version(input["shoestring"]),
      "elixir" => version(input["elixir"]),
      "otp" => digits(input["otp"]),
      "os" => member(input["os"], ~w(macos linux)),
      "architecture" => member(input["architecture"], ~w(arm64 x86_64)),
      "terminal_protocol" => integer(input["terminal_protocol"], 100),
      "release" => member(input["release"], ~w(release development))
    }
  end

  defp configuration(input) do
    monitors = object(input["capacity_monitors"])

    %{
      "forecast_enforcement" => boolean(input["forecast_enforcement"]),
      "api_enabled" => boolean(input["api_enabled"]),
      "api_cap_microusd" => integer(input["api_cap_microusd"]),
      "capacity_monitors" => %{
        "claude" => boolean(monitors["claude"]),
        "codex" => boolean(monitors["codex"])
      }
    }
  end

  defp health(input) do
    %{
      "repository" => member(input["repository"], ~w(readable)),
      "sqlite_version" => version(input["sqlite_version"]),
      "state_directory" =>
        member(input["state_directory"], ~w(read_write not_writable unavailable)),
      "provider_authentication" => "not_checked",
      "helper_compatibility" => "not_checked"
    }
  end

  defp fixtures(input) do
    Map.new(~w(codex-initialize-v1 claude-capacity-v1), fn name ->
      hash = input[name]

      valid =
        is_binary(hash) and byte_size(hash) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, hash)

      {name, if(valid, do: hash)}
    end)
  end

  # Explanations are local templates, never the stored free-text explanation.
  defp explanation("unknown"), do: "Stored reason omitted; inspect the local trajectory."

  defp explanation("automatic_admission_eligible"),
    do: "Static admission checks allowed execution."

  defp explanation(reason) when reason in ~w(no_observation no_observation_for_provider),
    do: "Admission is waiting for a provider capacity observation."

  defp explanation(_),
    do: "A recorded static admission constraint needs attention; inspect the local trajectory."

  defp aliases(events, key, prefix) do
    events
    |> Enum.map(key)
    |> Enum.filter(&(Ecto.UUID.cast(&1) != :error and not is_nil(&1)))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.with_index(1)
    |> Map.new(fn {id, n} -> {id, "#{prefix}-#{n}"} end)
  end

  defp time(%DateTime{} = time), do: DateTime.to_unix(time, :millisecond)
  defp time(_), do: nil
  defp object(value) when is_map(value), do: value
  defp object(_), do: %{}
  defp integer(value, max \\ 1_000_000_000_000)
  defp integer(value, max) when is_integer(value) and value >= 0 and value <= max, do: value
  defp integer(_, _), do: nil
  defp boolean(value) when is_boolean(value), do: value
  defp boolean(_), do: nil

  defp member(value, allowed, default \\ "unknown"),
    do: if(value in allowed, do: value, else: default)

  def version(value) when is_binary(value) and byte_size(value) <= 40 do
    if Regex.match?(~r/\A\d{1,5}(?:\.\d{1,5}){1,3}\z/, value), do: value, else: nil
  end

  def version(_), do: nil

  defp digits(value) when is_binary(value) and byte_size(value) <= 5 do
    if Regex.match?(~r/\A[0-9]+\z/, value), do: value, else: nil
  end

  defp digits(_), do: nil
end
