defmodule Shoestring.Cobbler.AdmissionEvaluation do
  @moduledoc """
  Pure deterministic admission evaluation.

  Evaluates admission requests against candidate providers, capacity observations,
  reserve policies, explicit occupancy evidence, and operator override confirmations.

  Guarantees:
  - Pure deterministic evaluation: requires explicit `now` DateTime input; no system clock reads.
  - Zero external calls or subprocess invocations.
  - Missing evidence stays unknown; never manufactures 0 usage.
  - Refuses automatic admission at reserve breaches (>= 80% five-hour, >= 90% weekly).
  - Hard boundaries (unsupported capability, incompatible CLI, hard quota block,
    reserve breach, scope mismatch, active occupancy) CANNOT be bypassed by manual confirmation.
  - Validates attributable single-decision confirmations against candidate, scope, and intent.
  - Never describes manual execution as automatically safe.
  - Prevents immediate retry loops on past reset timestamps via explicit delayed recheck.
  - Documents runtime transactional enforcement required (SQLite immediate/exclusive,
    not assumed Postgres SELECT FOR UPDATE).
  """

  alias Shoestring.Cobbler.{AdmissionDecision, AdmissionPolicy}
  alias Shoestring.Harness.{CapacitySnapshot, Contract}

  @doc """
  Evaluates admission for a single candidate provider deterministically.

  Options:
  - `:now` (required) - `%DateTime{}` in UTC. Evaluation raises/fails if missing.
  - `:occupancy` (optional) - Explicit occupancy evidence for the candidate scope.
  - `:decision_id` (optional) - UUID for the decision; generated if omitted.
  - `:extensions` (optional) - Map of extensions.
  """
  @spec evaluate(
          map(),
          map(),
          CapacitySnapshot.t() | map() | nil,
          AdmissionPolicy.t() | nil,
          keyword()
        ) ::
          {:ok, AdmissionDecision.t()} | {:error, term()}
  def evaluate(request, candidate, snapshot, policy \\ nil, opts \\ [])

  def evaluate(request, candidate, snapshot, policy, opts)
      when is_map(request) and is_map(candidate) and is_list(opts) do
    with {:ok, now} <- validate_now(opts),
         {:ok, policy} <- normalize_policy(policy),
         {:ok, candidate} <- normalize_candidate(candidate),
         {:ok, request} <- normalize_request(request, candidate) do
      do_evaluate(request, candidate, snapshot, policy, now, opts)
    end
  end

  def evaluate(_request, _candidate, _snapshot, _policy, _opts) do
    Contract.invalid(:base, "invalid arguments to evaluate/5")
  end

  @doc """
  Deterministically evaluates multiple candidates in policy-defined priority order.
  """
  @spec evaluate_candidates(map(), [map()], map(), AdmissionPolicy.t() | nil, keyword()) ::
          {:ok, %{selected: AdmissionDecision.t(), all: [AdmissionDecision.t()]}}
          | {:error, term()}
  def evaluate_candidates(request, candidates, snapshots_map, policy \\ nil, opts \\ [])
      when is_map(request) and is_list(candidates) and is_map(snapshots_map) and is_list(opts) do
    with {:ok, now} <- validate_now(opts),
         {:ok, policy} <- normalize_policy(policy) do
      sorted_candidates = sort_candidates_by_priority(candidates, policy.candidate_priority)

      decisions =
        Enum.map(sorted_candidates, fn candidate ->
          provider_id = Map.get(candidate, :provider_id, Map.get(candidate, "provider_id"))
          snapshot = Map.get(snapshots_map, provider_id)

          {:ok, decision} =
            evaluate(request, candidate, snapshot, policy, Keyword.put(opts, :now, now))

          decision
        end)

      selected = pick_best_decision(decisions)
      {:ok, %{selected: selected, all: decisions}}
    end
  end

  # ============================================================================
  # Internal Evaluation Pipeline
  # ============================================================================

  defp do_evaluate(request, candidate, snapshot, policy, now, opts) do
    decision_id = Keyword.get(opts, :decision_id) || Ecto.UUID.generate()
    occupancy = Keyword.get(opts, :occupancy, false)
    extensions = Keyword.get(opts, :extensions, %{})

    proposed_bounds = %{
      "response_budget" => policy.response_budget,
      "tool_budget" => policy.tool_budget,
      "deadline" => DateTime.to_iso8601(DateTime.add(now, policy.deadline_seconds, :second)),
      "checkpoint_cadence" => policy.checkpoint_cadence,
      "reserves" => %{
        "response" => policy.reserves.response,
        "tool" => policy.reserves.tool
      }
    }

    confirmation = request.override
    validated_override = validate_confirmation(confirmation, candidate)

    # 1. Hard unbypassable constraints
    # These checks cannot be overridden by manual confirmation under any circumstance.
    case check_hard_constraints(request, candidate, snapshot, policy, occupancy, now) do
      {:hard_stop, result, reason_code, explanation, defer_until, reobservation_req} ->
        build_decision(%{
          decision_id: decision_id,
          request: request,
          candidate: candidate,
          snapshot: snapshot,
          policy: policy,
          result: result,
          reason_code: reason_code,
          explanation: explanation,
          override: validated_override,
          proposed_bounds: proposed_bounds,
          defer_until: defer_until,
          reobservation_required: reobservation_req,
          evaluated_at: now,
          extensions: extensions
        })

      :pass ->
        # 2. Check automatic eligibility vs confirmation-required conditions
        evaluate_eligibility(
          request,
          candidate,
          snapshot,
          policy,
          validated_override,
          proposed_bounds,
          decision_id,
          now,
          extensions
        )
    end
  end

  # ----------------------------------------------------------------------------
  # Hard Unbypassable Constraints
  # ----------------------------------------------------------------------------

  defp check_hard_constraints(request, candidate, snapshot, policy, occupancy, now) do
    cond do
      # 1. Unsupported execution capability
      request.requested_capability not in candidate.capabilities ->
        {:hard_stop, :reject, "unsupported_capability",
         "Requested capability '#{request.requested_capability}' is not supported by candidate '#{candidate.provider_id}' (cannot be bypassed by confirmation)",
         nil, false}

      # 2. Incompatible CLI
      candidate.compatibility_state == :incompatible ->
        {:hard_stop, :reject, "incompatible_cli",
         "Candidate '#{candidate.provider_id}' CLI or adapter is incompatible with the environment (cannot be bypassed by confirmation)",
         nil, false}

      # 3. Unsupported support tier
      candidate.support_tier == :unsupported ->
        {:hard_stop, :reject, "unsupported_tier",
         "Candidate '#{candidate.provider_id}' support tier is unsupported (cannot be bypassed by confirmation)",
         nil, false}

      # 4. Scope mismatch
      request.scope != nil and request.scope != candidate.scope ->
        {:hard_stop, :reject, "scope_mismatch",
         "Requested scope '#{request.scope}' does not match candidate scope '#{candidate.scope}' (cannot be bypassed by confirmation)",
         nil, false}

      # 5. Active occupancy
      is_occupied?(occupancy, candidate) ->
        defer_until = DateTime.add(now, policy.delayed_recheck_seconds, :second)

        {:hard_stop, :defer_until, "scope_occupied",
         "Candidate scope '#{candidate.scope}' is currently occupied by active execution; manual confirmation cannot bypass active occupancy",
         defer_until, true}

      # 6. Hard quota refusal from provider
      is_refused?(snapshot) ->
        {defer_until, reason_code, explanation} = compute_refusal_deferral(snapshot, policy, now)

        {:hard_stop, :defer_until, reason_code,
         explanation <> "; manual confirmation cannot bypass hard quota block", defer_until, true}

      # 7. Known reserve breach on 5-hour window
      breach =
          check_window_breach(
            snapshot,
            "five_hour",
            policy.five_hour_max_used_percent,
            now,
            policy
          ) ->
        {defer_until, reason_code, explanation} = breach

        {:hard_stop, :defer_until, reason_code,
         explanation <> "; manual confirmation cannot bypass reserve breach", defer_until, true}

      # 8. Known reserve breach on weekly window
      breach =
          check_window_breach(snapshot, "weekly", policy.weekly_max_used_percent, now, policy) ->
        {defer_until, reason_code, explanation} = breach

        {:hard_stop, :defer_until, reason_code,
         explanation <> "; manual confirmation cannot bypass reserve breach", defer_until, true}

      true ->
        :pass
    end
  end

  # ----------------------------------------------------------------------------
  # Eligibility & Confirmation Evaluation
  # ----------------------------------------------------------------------------

  defp evaluate_eligibility(
         request,
         candidate,
         snapshot,
         policy,
         validated_override,
         proposed_bounds,
         decision_id,
         now,
         extensions
       ) do
    # Check bypassable eligibility conditions
    condition = check_bypassable_conditions(candidate, snapshot, policy, now)

    case condition do
      :eligible ->
        build_decision(%{
          decision_id: decision_id,
          request: request,
          candidate: candidate,
          snapshot: snapshot,
          policy: policy,
          result: :admit,
          reason_code: "automatic_admission_eligible",
          explanation:
            "Candidate '#{candidate.provider_id}' is eligible for automatic admission with fresh proactive observations within reserves",
          override: validated_override,
          proposed_bounds: proposed_bounds,
          defer_until: nil,
          reobservation_required: false,
          evaluated_at: now,
          extensions: extensions
        })

      {:requires_confirmation, primary_reason, primary_explanation} ->
        if override_valid?(validated_override) do
          # Single-decision attributable confirmation granted!
          # "never describe manual execution as automatically safe."
          confirmed_by = validated_override["confirmed_by"]
          intent = validated_override["intent"]

          build_decision(%{
            decision_id: decision_id,
            request: request,
            candidate: candidate,
            snapshot: snapshot,
            policy: policy,
            result: :admit,
            reason_code: "confirmed_" <> primary_reason,
            explanation:
              "Admitted via attributable single-decision confirmation by '#{confirmed_by}' (intent: '#{intent}'); not automatically safe (#{primary_explanation})",
            override: validated_override,
            proposed_bounds: proposed_bounds,
            defer_until: nil,
            reobservation_required: false,
            evaluated_at: now,
            extensions: extensions
          })
        else
          # Confirmation is absent or invalid
          reason_code =
            if validated_override && not validated_override["valid"] do
              "confirmation_invalid_" <> validated_override["reason"]
            else
              primary_reason
            end

          explanation =
            if validated_override && not validated_override["valid"] do
              "Confirmation rejected: #{validated_override["reason"]}; " <> primary_explanation
            else
              primary_explanation
            end

          build_decision(%{
            decision_id: decision_id,
            request: request,
            candidate: candidate,
            snapshot: snapshot,
            policy: policy,
            result: :require_confirmation,
            reason_code: reason_code,
            explanation: explanation,
            override: validated_override,
            proposed_bounds: proposed_bounds,
            defer_until: nil,
            reobservation_required: true,
            evaluated_at: now,
            extensions: extensions
          })
        end
    end
  end

  defp check_bypassable_conditions(candidate, snapshot, _policy, now) do
    cond do
      is_nil(snapshot) ->
        {:requires_confirmation, "unknown_capacity",
         "Capacity snapshot is missing or unknown; requires attributable single-decision confirmation"}

      snapshot_future?(snapshot, now) ->
        {:requires_confirmation, "future_observation",
         "Capacity observation has a future timestamp; treated as unknown, requires attributable confirmation"}

      snapshot_stale?(snapshot, now) ->
        {:requires_confirmation, "stale_observation",
         "Capacity observation is stale; requires fresh observation or attributable single-decision confirmation"}

      candidate.support_tier in [:conservative_partial, :reactive_only] or
          snapshot_tier(snapshot) in [:conservative_partial, :reactive_only] ->
        tier = candidate.support_tier

        {:requires_confirmation, "support_tier_#{tier}",
         "Candidate support tier '#{tier}' requires attributable single-decision confirmation"}

      snapshot_confidence(snapshot) != :high ->
        conf = snapshot_confidence(snapshot)

        {:requires_confirmation, "confidence_#{conf}",
         "Capacity confidence is '#{conf}'; automatic admission requires high confidence"}

      candidate.compatibility_state == :degraded or snapshot_compat(snapshot) == :degraded ->
        {:requires_confirmation, "degraded_compatibility",
         "Candidate compatibility state is degraded; requires attributable single-decision confirmation"}

      snapshot_state(snapshot) in [:unknown, :degraded] ->
        state = snapshot_state(snapshot)

        {:requires_confirmation, "capacity_state_#{state}",
         "Capacity state is #{state}; automatic admission requires observed state"}

      missing_or_unknown_window?(snapshot, "five_hour") ->
        kind_state = window_state_label(snapshot, "five_hour")

        {:requires_confirmation, "#{kind_state}_five_hour",
         "Five-hour observation window is #{kind_state}; requires attributable single-decision confirmation"}

      missing_or_unknown_window?(snapshot, "weekly") ->
        kind_state = window_state_label(snapshot, "weekly")

        {:requires_confirmation, "#{kind_state}_weekly",
         "Weekly observation window is #{kind_state}; requires attributable single-decision confirmation"}

      true ->
        :eligible
    end
  end

  # ----------------------------------------------------------------------------
  # Helper Calculations
  # ----------------------------------------------------------------------------

  defp is_occupied?(occupancy, _candidate) when is_boolean(occupancy), do: occupancy

  defp is_occupied?(occupancy, candidate) when is_map(occupancy) do
    cond do
      Map.get(occupancy, :active) == true or Map.get(occupancy, "active") == true ->
        true

      Map.get(occupancy, :occupied) == true or Map.get(occupancy, "occupied") == true ->
        true

      Map.get(occupancy, candidate.scope) == true ->
        true

      Map.get(occupancy, candidate.provider_id) == true ->
        true

      true ->
        false
    end
  end

  defp is_occupied?(occupancy, candidate) when is_list(occupancy) do
    Enum.any?(occupancy, fn item ->
      item == candidate.scope or item == candidate.provider_id or is_occupied?(item, candidate)
    end)
  end

  defp is_occupied?(_occupancy, _candidate), do: false

  defp is_refused?(nil), do: false
  defp is_refused?(%CapacitySnapshot{capacity_state: :refused}), do: true
  defp is_refused?(%{"capacity_state" => "refused"}), do: true
  defp is_refused?(_), do: false

  defp compute_refusal_deferral(snapshot, policy, now) do
    reset_at = extract_snapshot_reset_at(snapshot)
    reset_at = if reset_at, do: DateTime.truncate(reset_at, :microsecond)

    cond do
      reset_at && DateTime.compare(reset_at, now) == :gt ->
        {reset_at, "hard_quota_refusal_deferred",
         "Provider reported quota refusal; automatic admission blocked until reset at #{DateTime.to_iso8601(reset_at)}"}

      reset_at ->
        defer_until = DateTime.add(now, policy.delayed_recheck_seconds, :second)

        {defer_until, "past_reset_delayed_recheck",
         "Provider reported quota refusal with past reset timestamp; delayed recheck scheduled at #{DateTime.to_iso8601(defer_until)}"}

      true ->
        defer_until = DateTime.add(now, policy.delayed_recheck_seconds, :second)

        {defer_until, "hard_quota_refusal_delayed",
         "Provider reported quota refusal; delayed recheck scheduled at #{DateTime.to_iso8601(defer_until)}"}
    end
  end

  defp check_window_breach(nil, _kind, _max_used, _now, _policy), do: nil

  defp check_window_breach(snapshot, kind, max_used, now, policy) do
    case find_window(snapshot, kind) do
      %{state: :observed, used_percent: used_percent} = window
      when is_number(used_percent) and used_percent >= max_used ->
        build_breach_deferral(kind, used_percent, max_used, window.reset_at, now, policy)

      %{"state" => "observed", "used_percent" => used_percent} = window
      when is_number(used_percent) and used_percent >= max_used ->
        reset_at = parse_datetime(window["reset_at"])
        build_breach_deferral(kind, used_percent, max_used, reset_at, now, policy)

      _ ->
        nil
    end
  end

  defp build_breach_deferral(kind, used_percent, max_used, reset_at, now, policy) do
    reset_at = if reset_at, do: DateTime.truncate(reset_at, :microsecond)

    cond do
      reset_at && DateTime.compare(reset_at, now) == :gt ->
        {reset_at, "reserve_breach_#{kind}",
         "#{format_kind(kind)} quota used (#{used_percent}%) exceeds maximum allowable (#{max_used}%); deferred until reset at #{DateTime.to_iso8601(reset_at)}"}

      reset_at ->
        defer_until = DateTime.add(now, policy.delayed_recheck_seconds, :second)

        {defer_until, "past_reset_delayed_recheck",
         "#{format_kind(kind)} quota used (#{used_percent}%) exceeds maximum allowable (#{max_used}%) with past reset timestamp; delayed recheck scheduled at #{DateTime.to_iso8601(defer_until)}"}

      true ->
        defer_until = DateTime.add(now, policy.delayed_recheck_seconds, :second)

        {defer_until, "reserve_breach_#{kind}",
         "#{format_kind(kind)} quota used (#{used_percent}%) exceeds maximum allowable (#{max_used}%); delayed recheck scheduled at #{DateTime.to_iso8601(defer_until)}"}
    end
  end

  defp format_kind("five_hour"), do: "Five-hour"
  defp format_kind("weekly"), do: "Weekly"
  defp format_kind(k), do: k

  defp snapshot_future?(%CapacitySnapshot{observed_at: observed_at}, now)
       when not is_nil(observed_at) do
    DateTime.compare(observed_at, now) == :gt
  end

  defp snapshot_future?(%{"observed_at" => str}, now) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> DateTime.compare(dt, now) == :gt
      _ -> false
    end
  end

  defp snapshot_future?(_snapshot, _now), do: false

  defp snapshot_stale?(%CapacitySnapshot{expires_at: expires_at}, now)
       when not is_nil(expires_at) do
    DateTime.compare(now, expires_at) == :gt
  end

  defp snapshot_stale?(
         %CapacitySnapshot{observed_at: observed_at, freshness: %{max_age_seconds: max_age}},
         now
       )
       when not is_nil(observed_at) do
    expires_at = DateTime.add(observed_at, max_age, :second)
    DateTime.compare(now, expires_at) == :gt
  end

  defp snapshot_stale?(%{"expires_at" => str}, now) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> DateTime.compare(now, dt) == :gt
      _ -> false
    end
  end

  defp snapshot_stale?(_snapshot, _now), do: false

  defp snapshot_tier(%CapacitySnapshot{support_tier: tier}), do: tier

  defp snapshot_tier(%{"support_tier" => tier}) when is_binary(tier),
    do: String.to_existing_atom(tier)

  defp snapshot_tier(%{"support_tier" => tier}) when is_atom(tier), do: tier
  defp snapshot_tier(_), do: nil

  defp snapshot_confidence(%CapacitySnapshot{confidence: conf}), do: conf

  defp snapshot_confidence(%{"confidence" => conf}) when is_binary(conf),
    do: String.to_existing_atom(conf)

  defp snapshot_confidence(%{"confidence" => conf}) when is_atom(conf), do: conf
  defp snapshot_confidence(_), do: :none

  defp snapshot_compat(%CapacitySnapshot{compatibility_state: compat}), do: compat

  defp snapshot_compat(%{"compatibility_state" => compat}) when is_binary(compat),
    do: String.to_existing_atom(compat)

  defp snapshot_compat(%{"compatibility_state" => compat}) when is_atom(compat), do: compat
  defp snapshot_compat(_), do: nil

  defp snapshot_state(%CapacitySnapshot{capacity_state: state}), do: state

  defp snapshot_state(%{"capacity_state" => state}) when is_binary(state),
    do: String.to_existing_atom(state)

  defp snapshot_state(%{"capacity_state" => state}) when is_atom(state), do: state
  defp snapshot_state(_), do: :unknown

  defp missing_or_unknown_window?(snapshot, kind) do
    case find_window(snapshot, kind) do
      nil -> true
      %{state: :observed, used_percent: val} when is_number(val) -> false
      %{"state" => "observed", "used_percent" => val} when is_number(val) -> false
      _ -> true
    end
  end

  defp window_state_label(snapshot, kind) do
    case find_window(snapshot, kind) do
      nil -> "missing_window"
      _ -> "unknown_window"
    end
  end

  defp find_window(%CapacitySnapshot{windows: windows}, kind) when is_list(windows) do
    Enum.find(windows, &(&1.kind == kind))
  end

  defp find_window(%{"windows" => %{"items" => items}}, kind) when is_list(items) do
    Enum.find(items, fn item ->
      item["kind"] == kind or item[:kind] == kind
    end)
  end

  defp find_window(%{"windows" => windows}, kind) when is_list(windows) do
    Enum.find(windows, fn item ->
      item["kind"] == kind or item[:kind] == kind
    end)
  end

  defp find_window(_snapshot, _kind), do: nil

  defp extract_snapshot_reset_at(%CapacitySnapshot{windows: windows}) when is_list(windows) do
    windows
    |> Enum.map(& &1.reset_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort(&(DateTime.compare(&1, &2) == :gt))
    |> List.first()
  end

  defp extract_snapshot_reset_at(%{"windows" => %{"items" => items}}) when is_list(items) do
    items
    |> Enum.map(fn item -> parse_datetime(item["reset_at"] || item[:reset_at]) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort(&(DateTime.compare(&1, &2) == :gt))
    |> List.first()
  end

  defp extract_snapshot_reset_at(_), do: nil

  # ----------------------------------------------------------------------------
  # Confirmation / Override Validation
  # ----------------------------------------------------------------------------

  defp validate_confirmation(nil, _candidate), do: nil

  defp validate_confirmation(override, candidate) when is_map(override) do
    confirmed_by = Map.get(override, :confirmed_by, Map.get(override, "confirmed_by"))

    target_provider =
      Map.get(override, :target_provider_id, Map.get(override, "target_provider_id"))

    target_scope = Map.get(override, :target_scope, Map.get(override, "target_scope"))
    intent = Map.get(override, :intent, Map.get(override, "intent", "manual_execution"))
    confirmed_at = Map.get(override, :confirmed_at, Map.get(override, "confirmed_at"))

    cond do
      is_nil(confirmed_by) or String.trim(to_string(confirmed_by)) == "" ->
        %{
          "confirmed_by" => nil,
          "confirmed_at" => stringify_datetime(confirmed_at),
          "intent" => to_string(intent),
          "target_provider_id" => target_provider,
          "target_scope" => target_scope,
          "valid" => false,
          "reason" => "unattributed"
        }

      target_provider != nil and target_provider != candidate.provider_id ->
        %{
          "confirmed_by" => to_string(confirmed_by),
          "confirmed_at" => stringify_datetime(confirmed_at),
          "intent" => to_string(intent),
          "target_provider_id" => target_provider,
          "target_scope" => target_scope,
          "valid" => false,
          "reason" => "provider_mismatch"
        }

      target_scope != nil and target_scope != candidate.scope ->
        %{
          "confirmed_by" => to_string(confirmed_by),
          "confirmed_at" => stringify_datetime(confirmed_at),
          "intent" => to_string(intent),
          "target_provider_id" => target_provider,
          "target_scope" => target_scope,
          "valid" => false,
          "reason" => "scope_mismatch"
        }

      true ->
        %{
          "confirmed_by" => to_string(confirmed_by),
          "confirmed_at" => stringify_datetime(confirmed_at),
          "intent" => to_string(intent),
          "target_provider_id" => target_provider || candidate.provider_id,
          "target_scope" => target_scope || candidate.scope,
          "valid" => true,
          "reason" => "valid"
        }
    end
  end

  defp override_valid?(%{"valid" => true}), do: true
  defp override_valid?(_), do: false

  # ----------------------------------------------------------------------------
  # Observation Summarization (Preserves Missing Evidence as Unknown)
  # ----------------------------------------------------------------------------

  defp build_observation_evidence(nil, _now) do
    %{
      "snapshot_id" => nil,
      "observed_at" => nil,
      "expires_at" => nil,
      "age_seconds" => nil,
      "confidence" => "none",
      "freshness" => "unknown",
      "capacity_state" => "unknown",
      "windows" => [
        %{
          "kind" => "five_hour",
          "state" => "unknown",
          "used_percent" => nil,
          "reset_at" => nil,
          "reason" => "missing_snapshot"
        },
        %{
          "kind" => "weekly",
          "state" => "unknown",
          "used_percent" => nil,
          "reset_at" => nil,
          "reason" => "missing_snapshot"
        }
      ]
    }
  end

  defp build_observation_evidence(%CapacitySnapshot{} = s, now) do
    age =
      if s.observed_at && DateTime.compare(now, s.observed_at) in [:gt, :eq] do
        DateTime.diff(now, s.observed_at, :second)
      else
        nil
      end

    freshness_state =
      cond do
        is_nil(s.observed_at) -> "unknown"
        DateTime.compare(s.observed_at, now) == :gt -> "unknown"
        s.expires_at && DateTime.compare(now, s.expires_at) in [:lt, :eq] -> "fresh"
        true -> "stale"
      end

    windows_data =
      Enum.map(s.windows, fn w ->
        case w.state do
          :observed ->
            %{
              "kind" => w.kind,
              "state" => "observed",
              "used_percent" => w.used_percent,
              "reset_at" => stringify_datetime(w.reset_at),
              "reason" => nil
            }

          :unknown ->
            %{
              "kind" => w.kind,
              "state" => "unknown",
              "used_percent" => nil,
              "reset_at" => nil,
              "reason" => w.reason
            }
        end
      end)

    %{
      "snapshot_id" => s.snapshot_id,
      "observed_at" => stringify_datetime(s.observed_at),
      "expires_at" => stringify_datetime(s.expires_at),
      "age_seconds" => age,
      "confidence" => to_string(s.confidence),
      "freshness" => freshness_state,
      "capacity_state" => to_string(s.capacity_state),
      "windows" => windows_data
    }
  end

  defp build_observation_evidence(%{"contract_version" => _} = payload, now) do
    case CapacitySnapshot.from_payload(payload, now: now) do
      {:ok, snapshot} -> build_observation_evidence(snapshot, now)
      _ -> build_raw_observation_evidence(payload, now)
    end
  end

  defp build_observation_evidence(map, now) when is_map(map) do
    build_raw_observation_evidence(map, now)
  end

  defp build_raw_observation_evidence(payload, now) do
    observed_at = parse_datetime(payload["observed_at"] || payload[:observed_at])
    expires_at = parse_datetime(payload["expires_at"] || payload[:expires_at])

    age =
      if observed_at && DateTime.compare(now, observed_at) in [:gt, :eq] do
        DateTime.diff(now, observed_at, :second)
      else
        nil
      end

    freshness_state =
      cond do
        is_nil(observed_at) -> "unknown"
        DateTime.compare(observed_at, now) == :gt -> "unknown"
        expires_at && DateTime.compare(now, expires_at) in [:lt, :eq] -> "fresh"
        true -> "stale"
      end

    raw_windows =
      case payload["windows"] || payload[:windows] do
        %{"items" => items} -> items
        items when is_list(items) -> items
        _ -> []
      end

    windows_data =
      Enum.map(raw_windows, fn w ->
        state = to_string(w["state"] || w[:state] || "unknown")

        if state == "observed" do
          %{
            "kind" => to_string(w["kind"] || w[:kind]),
            "state" => "observed",
            "used_percent" => w["used_percent"] || w[:used_percent],
            "reset_at" => stringify_datetime(w["reset_at"] || w[:reset_at]),
            "reason" => nil
          }
        else
          %{
            "kind" => to_string(w["kind"] || w[:kind]),
            "state" => "unknown",
            "used_percent" => nil,
            "reset_at" => nil,
            "reason" => to_string(w["reason"] || w[:reason] || "unknown")
          }
        end
      end)

    %{
      "snapshot_id" => payload["snapshot_id"] || payload[:snapshot_id],
      "observed_at" => stringify_datetime(observed_at),
      "expires_at" => stringify_datetime(expires_at),
      "age_seconds" => age,
      "confidence" => to_string(payload["confidence"] || payload[:confidence] || "none"),
      "freshness" => freshness_state,
      "capacity_state" =>
        to_string(payload["capacity_state"] || payload[:capacity_state] || "unknown"),
      "windows" => windows_data
    }
  end

  # ----------------------------------------------------------------------------
  # Decision Builder
  # ----------------------------------------------------------------------------

  defp build_decision(params) do
    observation = build_observation_evidence(params.snapshot, params.evaluated_at)

    AdmissionDecision.new(%{
      version: 1,
      decision_id: params.decision_id,
      run_id: params.request.run_id,
      goal_id: params.request.goal_id,
      task_id: params.request.task_id,
      result: params.result,
      reason_code: params.reason_code,
      explanation: params.explanation,
      requested_capability: params.request.requested_capability,
      candidate: %{
        provider_id: params.candidate.provider_id,
        adapter_id: params.candidate.adapter_id,
        support_tier: params.candidate.support_tier,
        compatibility_state: params.candidate.compatibility_state
      },
      scope: params.candidate.scope,
      observation: observation,
      policy: AdmissionPolicy.to_map(params.policy),
      override: params.override,
      proposed_bounds: params.proposed_bounds,
      defer_until: params.defer_until,
      reobservation_required: params.reobservation_required,
      evaluated_at: params.evaluated_at,
      extensions: params.extensions
    })
  end

  # ----------------------------------------------------------------------------
  # Normalization & Parsing Helpers
  # ----------------------------------------------------------------------------

  defp validate_now(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{time_zone: "Etc/UTC"} = now ->
        {:ok, DateTime.truncate(now, :microsecond)}

      %DateTime{} = now ->
        {:ok, now |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:microsecond)}

      nil ->
        {:error, :missing_now_timestamp}

      _other ->
        {:error, :invalid_now_timestamp}
    end
  end

  defp normalize_policy(nil), do: {:ok, AdmissionPolicy.default()}
  defp normalize_policy(%AdmissionPolicy{} = p), do: {:ok, p}
  defp normalize_policy(map) when is_map(map), do: AdmissionPolicy.new(map)

  defp normalize_policy(_),
    do: Contract.invalid(:policy, "must be an AdmissionPolicy struct or map")

  defp normalize_candidate(candidate) when is_map(candidate) do
    provider_id = Map.get(candidate, :provider_id, Map.get(candidate, "provider_id"))
    adapter_id = Map.get(candidate, :adapter_id, Map.get(candidate, "adapter_id", provider_id))
    tier = Map.get(candidate, :support_tier, Map.get(candidate, "support_tier", :proactive))

    compat =
      Map.get(
        candidate,
        :compatibility_state,
        Map.get(candidate, "compatibility_state", :compatible)
      )

    scope = Map.get(candidate, :scope, Map.get(candidate, "scope", "account:#{provider_id}"))

    capabilities =
      Map.get(
        candidate,
        :capabilities,
        Map.get(candidate, "capabilities", ["supervised_execution"])
      )

    if is_binary(provider_id) and String.trim(provider_id) != "" do
      {:ok,
       %{
         provider_id: provider_id,
         adapter_id: to_string(adapter_id),
         support_tier: to_atom(tier),
         compatibility_state: to_atom(compat),
         scope: to_string(scope),
         capabilities: capabilities
       }}
    else
      Contract.invalid(:candidate, "must have a valid provider_id")
    end
  end

  defp normalize_request(request, candidate) when is_map(request) do
    cap =
      Map.get(
        request,
        :requested_capability,
        Map.get(request, "requested_capability", "supervised_execution")
      )

    scope = Map.get(request, :scope, Map.get(request, "scope", candidate.scope))
    run_id = Map.get(request, :run_id, Map.get(request, "run_id"))
    goal_id = Map.get(request, :goal_id, Map.get(request, "goal_id"))
    task_id = Map.get(request, :task_id, Map.get(request, "task_id"))

    override =
      Map.get(
        request,
        :override,
        Map.get(
          request,
          "override",
          Map.get(request, :confirmation, Map.get(request, "confirmation"))
        )
      )

    {:ok,
     %{
       requested_capability: to_string(cap),
       scope: if(scope, do: to_string(scope), else: nil),
       run_id: run_id,
       goal_id: goal_id,
       task_id: task_id,
       override: override
     }}
  end

  defp sort_candidates_by_priority(candidates, priority_list) do
    Enum.sort_by(candidates, fn candidate ->
      pid = Map.get(candidate, :provider_id, Map.get(candidate, "provider_id"))
      index = Enum.find_index(priority_list, &(&1 == pid))
      if index, do: index, else: 999
    end)
  end

  defp pick_best_decision([first | rest]) do
    Enum.reduce(rest, first, fn decision, best ->
      if decision_rank(decision.result) < decision_rank(best.result), do: decision, else: best
    end)
  end

  # Lower rank is preferred
  defp decision_rank(:admit), do: 1
  defp decision_rank(:require_confirmation), do: 2
  defp decision_rank(:defer_until), do: 3
  defp decision_rank(:reject), do: 4

  defp to_atom(val) when is_atom(val), do: val

  defp to_atom(val) when is_binary(val) do
    try do
      String.to_existing_atom(val)
    rescue
      ArgumentError -> String.to_atom(val)
    end
  end

  defp to_atom(val), do: val

  defp stringify_datetime(nil), do: nil
  defp stringify_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp stringify_datetime(str) when is_binary(str), do: str
  defp stringify_datetime(_), do: nil

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: DateTime.truncate(dt, :microsecond)

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :microsecond)
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil
end
