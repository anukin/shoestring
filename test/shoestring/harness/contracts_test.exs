defmodule Shoestring.Harness.ContractsTest do
  use ExUnit.Case, async: true

  alias Shoestring.Harness.{
    CapacitySnapshot,
    Checkpoint,
    EventPayload,
    ExecutionLease,
    HarnessEvent,
    RunRequest
  }

  alias Shoestring.Trajectory.EventRegistry

  @goal_id "00000000-0000-4000-8000-000000000001"
  @task_id "00000000-0000-4000-8000-000000000002"
  @run_id "00000000-0000-4000-8000-000000000003"
  @dispatch_id "00000000-0000-4000-8000-000000000004"
  @snapshot_id "00000000-0000-4000-8000-000000000005"
  @grant_id "00000000-0000-4000-8000-000000000006"
  @checkpoint_id "00000000-0000-4000-8000-000000000007"
  @now ~U[2026-08-30 12:00:00Z]

  test "public contracts construct typed normalized values" do
    assert {:ok, %RunRequest{version: 1, requested_capabilities: [:resume]}} =
             RunRequest.new(run_request_attrs())

    assert {:ok, %HarnessEvent{kind: :result, result: %{status: "completed"}}} =
             HarnessEvent.new(%{
               version: 1,
               run_id: @run_id,
               source_event_id: "event-1",
               ordinal: 1,
               occurred_at: @now,
               kind: :result,
               result: %{status: "completed"}
             })

    assert {:ok,
            %CapacitySnapshot{
              version: 2,
              capacity_state: :observed,
              source: %{event: :explicit_read, provider_id: "codex"}
            }} =
             CapacitySnapshot.new(observed_snapshot_attrs(), now: @now)

    assert {:ok, %ExecutionLease{grant_id: @grant_id, reserves: %{response: 1, tool: 2}}} =
             ExecutionLease.new(lease_attrs())

    assert {:ok, %Checkpoint{checkpoint_id: @checkpoint_id}} =
             Checkpoint.new(checkpoint_attrs())
  end

  test "provider and mode support metadata distinguishes proactive Codex from Claude telemetry" do
    assert {:ok, codex} = CapacitySnapshot.new(observed_snapshot_attrs(), now: @now)
    assert codex.support_tier == :proactive
    assert codex.source.provider_id == "codex"
    assert codex.source.invocation_mode == "app_server"
    assert codex.compatibility_state == :compatible
    assert CapacitySnapshot.eligible?(codex, @now)

    assert {:error, claude_interactive_error} =
             CapacitySnapshot.new(
               observed_snapshot_attrs(%{
                 source: %{
                   adapter_id: "fixture.capacity",
                   provider_id: "claude",
                   invocation_mode: "interactive_status_line",
                   event: :status_line_input
                 },
                 support_tier: :conservative_partial
               }),
               now: @now
             )

    assert "observed capacity requires proactive support" in errors_on(claude_interactive_error).support_tier

    for non_proactive_tier <- [:reactive_only, :unsupported] do
      assert {:error, changeset} =
               CapacitySnapshot.new(
                 observed_snapshot_attrs(%{support_tier: non_proactive_tier}),
                 now: @now
               )

      assert "observed capacity requires proactive support" in errors_on(changeset).support_tier
    end

    assert {:ok, claude_degraded} =
             CapacitySnapshot.new(
               degraded_snapshot_attrs(%{
                 source: %{
                   adapter_id: "fixture.capacity",
                   provider_id: "claude",
                   invocation_mode: "interactive_status_line",
                   event: :status_line_input
                 },
                 support_tier: :conservative_partial
               }),
               now: @now
             )

    refute CapacitySnapshot.eligible?(claude_degraded, @now)

    assert {:ok, startup_omission} =
             CapacitySnapshot.new(
               unknown_snapshot_attrs(%{
                 source: %{
                   adapter_id: "fixture.capacity",
                   provider_id: "claude",
                   invocation_mode: "interactive_status_line",
                   event: :status_line_input
                 },
                 support_tier: :conservative_partial,
                 reason: "rate_limits_absent_before_first_response_or_unsupported_subscription"
               }),
               now: @now
             )

    assert {:ok, headless_unsupported} =
             CapacitySnapshot.new(
               unknown_snapshot_attrs(%{
                 source: %{
                   adapter_id: "fixture.capacity",
                   provider_id: "claude",
                   invocation_mode: "print_json",
                   event: :headless_result_error
                 },
                 support_tier: :unsupported,
                 reason: "headless_capacity_signal_unsupported"
               }),
               now: @now
             )

    assert startup_omission.reason != headless_unsupported.reason
    refute CapacitySnapshot.eligible?(startup_omission, @now)
    refute CapacitySnapshot.eligible?(headless_unsupported, @now)
  end

  test "freshness is deterministic, bounded, and never treats future data as fresh" do
    assert {:ok, codex} = CapacitySnapshot.new(observed_snapshot_attrs(), now: @now)
    assert codex.freshness.max_age_seconds == 300
    assert codex.expires_at == ~U[2026-08-30 12:05:00Z]
    assert CapacitySnapshot.freshness(codex, ~U[2026-08-30 12:05:00Z]) == :fresh
    assert CapacitySnapshot.freshness(codex, ~U[2026-08-30 12:05:01Z]) == :stale
    refute CapacitySnapshot.eligible?(codex, ~U[2026-08-30 12:05:01Z])

    assert {:ok, non_codex_policy} =
             CapacitySnapshot.new(
               observed_snapshot_attrs(%{freshness: %{max_age_seconds: 600}}),
               now: @now
             )

    assert non_codex_policy.expires_at == ~U[2026-08-30 12:10:00Z]

    assert {:error, changeset} =
             CapacitySnapshot.new(
               observed_snapshot_attrs(%{freshness: %{max_age_seconds: 86_401}}),
               now: @now
             )

    assert "must not exceed 86400" in errors_on(changeset).max_age_seconds

    assert {:ok, future} =
             CapacitySnapshot.new(
               unknown_snapshot_attrs(%{
                 observed_at: ~U[2026-08-30 12:00:01Z],
                 reason: "future_observation_timestamp"
               }),
               now: @now
             )

    assert CapacitySnapshot.freshness(future, @now) == :unknown
    refute CapacitySnapshot.eligible?(future, @now)

    assert {:error, changeset} =
             CapacitySnapshot.new(
               observed_snapshot_attrs(%{observed_at: ~U[2026-08-30 12:00:01Z]}),
               now: @now
             )

    assert "future capacity must be unknown" in errors_on(changeset).capacity_state
  end

  test "missing, malformed, timestamp-unknown, stale, disconnected, refused, and all-unknown observations fail closed" do
    assert {:ok, timestamp_unknown} =
             CapacitySnapshot.new(
               unknown_snapshot_attrs(%{
                 observed_at: nil,
                 reason: "missing_or_invalid_observation_timestamp"
               }),
               now: @now
             )

    assert CapacitySnapshot.freshness(timestamp_unknown, @now) == :unknown
    refute CapacitySnapshot.eligible?(timestamp_unknown, @now)

    assert {:ok, stale} =
             CapacitySnapshot.new(
               degraded_snapshot_attrs(%{
                 observed_at: ~U[2026-08-30 11:54:59Z],
                 reason: "stale_observation"
               }),
               now: @now
             )

    assert CapacitySnapshot.freshness(stale, @now) == :stale
    refute CapacitySnapshot.eligible?(stale, @now)

    assert {:ok, disconnected} =
             CapacitySnapshot.new(
               unknown_snapshot_attrs(%{reason: "transport_disconnected"}),
               now: @now
             )

    assert {:ok, generic_error} =
             CapacitySnapshot.new(
               unknown_snapshot_attrs(%{
                 source: %{
                   adapter_id: "fixture.capacity",
                   provider_id: "codex",
                   invocation_mode: "app_server",
                   event: :headless_result_error
                 },
                 reason: "provider_error"
               }),
               now: @now
             )

    assert CapacitySnapshot.freshness(generic_error, @now) == :unknown

    assert {:ok, refused} =
             CapacitySnapshot.new(
               %{
                 version: 2,
                 snapshot_id: @snapshot_id,
                 capacity_state: :refused,
                 windows: [],
                 observed_at: nil,
                 freshness: %{max_age_seconds: 300},
                 source: %{
                   adapter_id: "fixture.capacity",
                   provider_id: "codex",
                   invocation_mode: "app_server",
                   event: :explicit_read
                 },
                 scope: "account",
                 confidence: :none,
                 support_tier: :proactive,
                 compatibility_state: :compatible,
                 reason: "provider_reported_rate_limit_reached",
                 extensions: %{}
               },
               now: @now
             )

    assert {:ok, all_unknown_windows} =
             CapacitySnapshot.new(
               unknown_snapshot_attrs(%{
                 windows: [
                   %{kind: "primary", state: :unknown, reason: "missing_bucket"},
                   %{kind: "secondary", state: :unknown, reason: "malformed_bucket"}
                 ],
                 reason: "no_valid_windows"
               }),
               now: @now
             )

    for snapshot <- [disconnected, generic_error, refused, all_unknown_windows] do
      refute CapacitySnapshot.eligible?(snapshot, @now)
    end

    assert {:error, changeset} =
             CapacitySnapshot.new(
               %{
                 version: 2,
                 snapshot_id: @snapshot_id,
                 capacity_state: :refused,
                 windows: [],
                 observed_at: nil,
                 freshness: %{max_age_seconds: 300},
                 source: %{
                   adapter_id: "fixture.capacity",
                   provider_id: "claude",
                   invocation_mode: "print_json",
                   event: :headless_result_error
                 },
                 scope: "account",
                 confidence: :none,
                 support_tier: :unsupported,
                 compatibility_state: :degraded,
                 reason: "headless_capacity_signal_unsupported",
                 extensions: %{}
               },
               now: @now
             )

    assert "unsupported sources cannot report a refusal" in errors_on(changeset).support_tier

    assert {:error, changeset} =
             CapacitySnapshot.new(
               unknown_snapshot_attrs(%{
                 capacity_state: :refused,
                 confidence: :high,
                 support_tier: :proactive,
                 reason: "reported_limit"
               }),
               now: @now
             )

    assert "refused capacity cannot have high confidence" in errors_on(changeset).confidence

    assert {:error, changeset} =
             CapacitySnapshot.new(
               observed_snapshot_attrs(%{
                 capacity_state: :refused,
                 confidence: :none,
                 reason: "reported_limit"
               }),
               now: @now
             )

    assert "refused capacity cannot contain observed windows" in errors_on(changeset).windows

    assert {:error, changeset} =
             CapacitySnapshot.new(
               observed_snapshot_attrs(%{
                 windows: [%{kind: "primary", state: :observed, used_percent: "0"}]
               }),
               now: @now
             )

    assert "must be between 0 and 100" in errors_on(changeset).used_percent

    assert {:error, changeset} =
             CapacitySnapshot.new(
               observed_snapshot_attrs(%{
                 windows: [%{kind: "primary", state: :observed}]
               }),
               now: @now
             )

    assert "must be between 0 and 100" in errors_on(changeset).used_percent

    assert {:error, changeset} =
             CapacitySnapshot.new(Map.delete(observed_snapshot_attrs(), :observed_at), now: @now)

    assert "can't be blank" in errors_on(changeset).observed_at
  end

  test "capacity serialization allows additive fields but rejects state or shape drift" do
    assert {:ok, snapshot} = CapacitySnapshot.new(observed_snapshot_attrs(), now: @now)
    payload = EventPayload.capacity_snapshot(snapshot, @run_id)

    assert {:ok, ^payload} =
             EventRegistry.validate_payload("capacity.snapshot_observed", 2, payload, now: @now)

    assert {:ok, decoded} = CapacitySnapshot.from_payload(payload, now: @now)
    assert decoded == snapshot

    equivalent_expiry = Map.put(payload, "expires_at", "2026-08-30T05:05:00-07:00")

    assert {:ok, _decoded} =
             EventRegistry.validate_payload(
               "capacity.snapshot_observed",
               2,
               equivalent_expiry,
               now: @now
             )

    assert {:ok, additive_payload} =
             EventRegistry.validate_payload(
               "capacity.snapshot_observed",
               2,
               put_in(payload, ["source", "format"], "future-format")
               |> Map.put("future_field", "ignored"),
               now: @now
             )

    assert additive_payload["capacity_state"] == "observed"

    assert {:error, {:invalid_payload, "capacity.snapshot_observed", 2, _changeset}} =
             EventRegistry.validate_payload(
               "capacity.snapshot_observed",
               2,
               Map.put(payload, "support_tier", "reactive_only"),
               now: @now
             )

    for malformed <- [
          put_in(payload, ["capacity_state"], "available"),
          put_in(payload, ["windows", "items", Access.at(0), "state"], "known"),
          put_in(payload, ["source", "event"], "terminal_scrape"),
          put_in(payload, ["freshness", "max_age_seconds"], 0),
          put_in(payload, ["expires_at"], "2026-08-30T12:05:01Z"),
          put_in(payload, ["windows", "items", Access.at(0)], %{
            "kind" => "primary",
            "state" => "observed"
          }),
          put_in(payload, ["windows", "items", Access.at(0)], %{
            "kind" => "primary",
            "used_percent" => 25.0
          }),
          Map.delete(payload, "observed_at"),
          Map.delete(payload, "expires_at")
        ] do
      assert {:error, {:invalid_payload, "capacity.snapshot_observed", 2, _changeset}} =
               EventRegistry.validate_payload("capacity.snapshot_observed", 2, malformed,
                 now: @now
               )
    end
  end

  test "payload state contradictions are rejected at the JSON boundary" do
    {:ok, observed_snapshot} = CapacitySnapshot.new(observed_snapshot_attrs(), now: @now)
    observed = EventPayload.capacity_snapshot(observed_snapshot, @run_id)

    assert {:error, changeset} =
             CapacitySnapshot.from_payload(
               put_in(observed, ["windows", "items", Access.at(0), "reason"], "contradiction"),
               now: @now
             )

    assert "is not allowed for this state" in errors_on(changeset).window_reason

    assert {:error, changeset} =
             CapacitySnapshot.from_payload(Map.put(observed, "future_field", "secret: value"),
               now: @now
             )

    refute inspect(errors_on(changeset)) =~ "secret: value"

    unknown_attrs =
      unknown_snapshot_attrs(%{
        windows: [%{kind: "primary", state: :unknown, reason: "not_reported"}]
      })

    {:ok, unknown_snapshot} = CapacitySnapshot.new(unknown_attrs, now: @now)
    unknown = EventPayload.capacity_snapshot(unknown_snapshot, @run_id)

    for contradictory <- [
          put_in(unknown, ["windows", "items", Access.at(0), "used_percent"], 25.0),
          put_in(unknown, ["windows", "items", Access.at(0), "reset_at"], "2026-08-30T13:00:00Z")
        ] do
      assert {:error, _changeset} = CapacitySnapshot.from_payload(contradictory, now: @now)
    end
  end

  test "contract versions and extensions are explicit and bounded" do
    assert {:error, changeset} = RunRequest.new(Map.put(run_request_attrs(), :version, 2))
    assert "must equal 1" in errors_on(changeset).version

    assert {:error, changeset} =
             RunRequest.new(put_in(run_request_attrs(), [:extensions], %{"unscoped" => "value"}))

    assert "keys must be namespaced" in errors_on(changeset).extensions

    assert {:error, changeset} =
             RunRequest.new(Map.put(run_request_attrs(), :prompt, "Bearer abc.def.ghi"))

    assert "must not contain secrets" in errors_on(changeset).prompt
  end

  test "normalized error categories distinguish every required failure boundary" do
    assert Shoestring.Harness.Error.categories() == [
             :transport,
             :schema_incompatible,
             :authentication_required,
             :quota_refused,
             :cancelled,
             :task_failed,
             :invalid_transition,
             :unsupported_capability
           ]

    assert {:ok, %HarnessEvent{error: %{category: :quota_refused}}} =
             HarnessEvent.new(%{
               version: 1,
               run_id: @run_id,
               source_event_id: "quota-1",
               ordinal: 1,
               occurred_at: @now,
               kind: :error,
               error: %{category: "quota_refused", code: "limit", message: "Capacity refused"}
             })
  end

  test "a minimum checkpoint does not require model-authored text or a summary" do
    attrs = checkpoint_attrs()
    refute Map.has_key?(attrs, :summary)
    refute Map.has_key?(attrs, :model_response)

    assert {:ok, checkpoint} = Checkpoint.new(attrs)
    assert checkpoint.evidence == []
    assert checkpoint.decisions == []
    assert checkpoint.unresolved_issues == []
  end

  test "raw transcripts are rejected in durable extension structures" do
    assert {:error, changeset} =
             Checkpoint.new(
               put_in(checkpoint_attrs(), [:extensions], %{
                 "test.adapter:raw_output" => "not allowed"
               })
             )

    assert "must not contain secrets or raw transcripts" in errors_on(changeset).extensions
  end

  test "event payloads are JSON-safe and registered at their exact schemas" do
    assert {:ok, request} = RunRequest.new(run_request_attrs())
    assert {:ok, snapshot} = CapacitySnapshot.new(observed_snapshot_attrs(), now: @now)
    assert {:ok, lease} = ExecutionLease.new(lease_attrs())
    assert {:ok, checkpoint} = Checkpoint.new(checkpoint_attrs())

    assert {:ok, harness_event} =
             HarnessEvent.new(%{
               version: 1,
               run_id: @run_id,
               source_event_id: "result-1",
               ordinal: 1,
               occurred_at: @now,
               kind: :result,
               result: %{status: "completed"}
             })

    assert {:ok, _payload} =
             EventRegistry.validate_payload(
               "run.requested",
               1,
               EventPayload.run_requested(request, @run_id, "test.adapter")
             )

    assert {:ok, _payload} =
             EventRegistry.validate_payload(
               "dispatch.requested",
               1,
               EventPayload.dispatch_requested(%{
                 dispatch_id: @dispatch_id,
                 run_id: @run_id,
                 request_version: 1
               })
             )

    assert {:ok, _payload} =
             EventRegistry.validate_payload(
               "capacity.snapshot_observed",
               2,
               EventPayload.capacity_snapshot(snapshot, @run_id),
               now: @now
             )

    assert {:ok, _payload} =
             EventRegistry.validate_payload(
               "lease.proposed",
               1,
               EventPayload.execution_lease(lease)
             )

    assert {:ok, _payload} =
             EventRegistry.validate_payload(
               "checkpoint.created",
               1,
               EventPayload.checkpoint(checkpoint)
             )

    assert {:ok, _payload} =
             EventRegistry.validate_payload(
               "harness.event_recorded",
               1,
               EventPayload.harness_event(harness_event)
             )
  end

  defp observed_snapshot_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        version: 2,
        snapshot_id: @snapshot_id,
        capacity_state: :observed,
        windows: [
          %{
            kind: "primary",
            state: :observed,
            used_percent: 25.0,
            reset_at: ~U[2026-08-30 13:00:00Z]
          },
          %{
            kind: "secondary",
            state: :observed,
            used_percent: 40.0,
            reset_at: ~U[2026-09-06 12:00:00Z]
          }
        ],
        observed_at: @now,
        freshness: %{max_age_seconds: 300},
        source: %{
          adapter_id: "fixture.capacity",
          provider_id: "codex",
          invocation_mode: "app_server",
          event: :explicit_read
        },
        scope: "account",
        confidence: :high,
        support_tier: :proactive,
        compatibility_state: :compatible,
        reason: nil,
        extensions: %{}
      },
      overrides
    )
  end

  defp degraded_snapshot_attrs(overrides) do
    Map.merge(
      observed_snapshot_attrs(%{
        capacity_state: :degraded,
        windows: [
          %{kind: "primary", state: :observed, used_percent: 25.0},
          %{kind: "secondary", state: :unknown, reason: "missing_bucket"}
        ],
        confidence: :medium,
        compatibility_state: :degraded,
        reason: "partial_window"
      }),
      overrides
    )
  end

  defp unknown_snapshot_attrs(overrides) do
    Map.merge(
      %{
        version: 2,
        snapshot_id: @snapshot_id,
        capacity_state: :unknown,
        windows: [],
        observed_at: @now,
        freshness: %{max_age_seconds: 300},
        source: %{
          adapter_id: "fixture.capacity",
          provider_id: "codex",
          invocation_mode: "app_server",
          event: :none
        },
        scope: "account",
        confidence: :none,
        support_tier: :unsupported,
        compatibility_state: :degraded,
        reason: "provider_error",
        extensions: %{}
      },
      overrides
    )
  end

  defp run_request_attrs do
    %{
      version: 1,
      goal_id: @goal_id,
      task_id: @task_id,
      workspace_ref: "workspace/project",
      prompt: "Implement the next action.",
      policy: %{mode: "supervised", network: false, write_access: true},
      requested_capabilities: [:resume],
      dispatch_id: @dispatch_id,
      extensions: %{"test.adapter:mode" => "scripted"}
    }
  end

  defp lease_attrs do
    %{
      version: 1,
      grant_id: @grant_id,
      run_id: @run_id,
      admitted_snapshot_id: @snapshot_id,
      reserves: %{response: 1, tool: 2},
      response_budget: 4,
      tool_budget: 8,
      deadline: ~U[2026-08-30 12:15:00Z],
      checkpoint_cadence: 2,
      renewal_state: :eligible,
      extensions: %{}
    }
  end

  defp checkpoint_attrs do
    %{
      version: 1,
      checkpoint_id: @checkpoint_id,
      goal_id: @goal_id,
      run_id: @run_id,
      acceptance_contract: %{criteria: ["Focused tests are green"]},
      repository_state: %{revision: "unknown", dirty: false},
      evidence: [],
      decisions: [],
      unresolved_issues: [],
      next_action: "Resume at the next safe boundary.",
      provider_session_id: nil,
      stop_reason: "quota_refused",
      artifact_ids: [],
      extensions: %{}
    }
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end
end
