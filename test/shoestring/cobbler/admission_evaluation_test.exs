defmodule Shoestring.Cobbler.AdmissionEvaluationTest do
  use Shoestring.DataCase, async: false

  alias Shoestring.Cobbler.{AdmissionDecision, AdmissionEvaluation, AdmissionPolicy}
  alias Shoestring.Harness.CapacitySnapshot
  alias Shoestring.Trajectory
  alias Shoestring.Trajectory.Goal

  @now ~U[2026-09-07 14:00:00.000000Z]

  @default_candidate %{
    provider_id: "codex",
    adapter_id: "codex_app_server",
    support_tier: :proactive,
    compatibility_state: :compatible,
    scope: "account:codex-default",
    capabilities: ["supervised_execution", "read_only"]
  }

  defp build_snapshot(attrs) do
    string_attrs =
      attrs
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Map.new()

    default_attrs = %{
      "contract_version" => 2,
      "snapshot_id" => Ecto.UUID.generate(),
      "capacity_state" => "observed",
      "windows" => %{
        "items" => [
          %{
            "kind" => "five_hour",
            "state" => "observed",
            "used_percent" => 50.0,
            "reset_at" => "2026-09-07T18:00:00Z"
          },
          %{
            "kind" => "weekly",
            "state" => "observed",
            "used_percent" => 50.0,
            "reset_at" => "2026-09-14T00:00:00Z"
          }
        ]
      },
      "freshness" => %{"max_age_seconds" => 300},
      "source" => %{
        "adapter_id" => "codex_app_server",
        "provider_id" => "codex",
        "invocation_mode" => "app_server",
        "event" => "explicit_read"
      },
      "scope" => "account:codex-default",
      "confidence" => "high",
      "support_tier" => "proactive",
      "compatibility_state" => "compatible",
      "observed_at" => "2026-09-07T13:58:00Z",
      "expires_at" => "2026-09-07T14:03:00Z",
      "extensions" => %{}
    }

    merged = Map.merge(default_attrs, string_attrs)
    {:ok, snapshot} = CapacitySnapshot.from_payload(merged, now: @now)
    snapshot
  end

  describe "Purity & Determinism" do
    test "requires explicit now timestamp" do
      snapshot = build_snapshot(%{})

      assert {:error, :missing_now_timestamp} =
               AdmissionEvaluation.evaluate(%{}, @default_candidate, snapshot, nil, [])
    end

    test "produces identical decisions for identical inputs" do
      snapshot = build_snapshot(%{})
      opts = [now: @now, decision_id: "01950000-0000-7000-8000-000000000001"]

      {:ok, decision1} =
        AdmissionEvaluation.evaluate(%{}, @default_candidate, snapshot, nil, opts)

      {:ok, decision2} =
        AdmissionEvaluation.evaluate(%{}, @default_candidate, snapshot, nil, opts)

      assert decision1 == decision2
      assert AdmissionDecision.to_payload(decision1) == AdmissionDecision.to_payload(decision2)
    end
  end

  describe "Exact Reserve Thresholds" do
    test "five-hour window threshold boundary: 79% admit, 80% and 81% defer" do
      policy = AdmissionPolicy.default()

      # 79% used -> Remaining 21% > 20% reserve -> Admitted
      snap_79 =
        build_snapshot(%{
          windows: %{
            "items" => [
              %{
                "kind" => "five_hour",
                "state" => "observed",
                "used_percent" => 79.0,
                "reset_at" => "2026-09-07T18:00:00Z"
              },
              %{
                "kind" => "weekly",
                "state" => "observed",
                "used_percent" => 50.0,
                "reset_at" => "2026-09-14T00:00:00Z"
              }
            ]
          }
        })

      assert {:ok, d79} =
               AdmissionEvaluation.evaluate(%{}, @default_candidate, snap_79, policy, now: @now)

      assert d79.result == :admit
      assert d79.reason_code == "automatic_admission_eligible"

      # 80% used -> Reserve breach (>= 80%) -> Deferred
      snap_80 =
        build_snapshot(%{
          windows: %{
            "items" => [
              %{
                "kind" => "five_hour",
                "state" => "observed",
                "used_percent" => 80.0,
                "reset_at" => "2026-09-07T18:00:00Z"
              },
              %{
                "kind" => "weekly",
                "state" => "observed",
                "used_percent" => 50.0,
                "reset_at" => "2026-09-14T00:00:00Z"
              }
            ]
          }
        })

      assert {:ok, d80} =
               AdmissionEvaluation.evaluate(%{}, @default_candidate, snap_80, policy, now: @now)

      assert d80.result == :defer_until
      assert d80.reason_code == "reserve_breach_five_hour"
      assert d80.defer_until == ~U[2026-09-07 18:00:00Z]
      assert d80.reobservation_required == true

      # 81% used -> Reserve breach -> Deferred
      snap_81 =
        build_snapshot(%{
          windows: %{
            "items" => [
              %{
                "kind" => "five_hour",
                "state" => "observed",
                "used_percent" => 81.0,
                "reset_at" => "2026-09-07T18:00:00Z"
              },
              %{
                "kind" => "weekly",
                "state" => "observed",
                "used_percent" => 50.0,
                "reset_at" => "2026-09-14T00:00:00Z"
              }
            ]
          }
        })

      assert {:ok, d81} =
               AdmissionEvaluation.evaluate(%{}, @default_candidate, snap_81, policy, now: @now)

      assert d81.result == :defer_until
      assert d81.reason_code == "reserve_breach_five_hour"
    end

    test "weekly window threshold boundary: 89% admit, 90% and 91% defer" do
      policy = AdmissionPolicy.default()

      # 89% used -> Remaining 11% > 10% reserve -> Admitted
      snap_89 =
        build_snapshot(%{
          windows: %{
            "items" => [
              %{
                "kind" => "five_hour",
                "state" => "observed",
                "used_percent" => 50.0,
                "reset_at" => "2026-09-07T18:00:00Z"
              },
              %{
                "kind" => "weekly",
                "state" => "observed",
                "used_percent" => 89.0,
                "reset_at" => "2026-09-14T00:00:00Z"
              }
            ]
          }
        })

      assert {:ok, d89} =
               AdmissionEvaluation.evaluate(%{}, @default_candidate, snap_89, policy, now: @now)

      assert d89.result == :admit
      assert d89.reason_code == "automatic_admission_eligible"

      # 90% used -> Reserve breach (>= 90%) -> Deferred
      snap_90 =
        build_snapshot(%{
          windows: %{
            "items" => [
              %{
                "kind" => "five_hour",
                "state" => "observed",
                "used_percent" => 50.0,
                "reset_at" => "2026-09-07T18:00:00Z"
              },
              %{
                "kind" => "weekly",
                "state" => "observed",
                "used_percent" => 90.0,
                "reset_at" => "2026-09-14T00:00:00Z"
              }
            ]
          }
        })

      assert {:ok, d90} =
               AdmissionEvaluation.evaluate(%{}, @default_candidate, snap_90, policy, now: @now)

      assert d90.result == :defer_until
      assert d90.reason_code == "reserve_breach_weekly"
      assert d90.defer_until == ~U[2026-09-14 00:00:00Z]

      # 91% used -> Reserve breach -> Deferred
      snap_91 =
        build_snapshot(%{
          windows: %{
            "items" => [
              %{
                "kind" => "five_hour",
                "state" => "observed",
                "used_percent" => 50.0,
                "reset_at" => "2026-09-07T18:00:00Z"
              },
              %{
                "kind" => "weekly",
                "state" => "observed",
                "used_percent" => 91.0,
                "reset_at" => "2026-09-14T00:00:00Z"
              }
            ]
          }
        })

      assert {:ok, d91} =
               AdmissionEvaluation.evaluate(%{}, @default_candidate, snap_91, policy, now: @now)

      assert d91.result == :defer_until
      assert d91.reason_code == "reserve_breach_weekly"
    end
  end

  describe "Missing and Malformed Windows" do
    test "missing five_hour window requires confirmation" do
      snap =
        build_snapshot(%{
          windows: %{
            "items" => [
              %{
                "kind" => "weekly",
                "state" => "observed",
                "used_percent" => 50.0,
                "reset_at" => "2026-09-14T00:00:00Z"
              }
            ]
          }
        })

      assert {:ok, decision} =
               AdmissionEvaluation.evaluate(%{}, @default_candidate, snap, nil, now: @now)

      assert decision.result == :require_confirmation
      assert decision.reason_code == "missing_window_five_hour"

      # Missing evidence is preserved as unknown, never 0
      fh = Enum.find(decision.observation["windows"], &(&1["kind"] == "five_hour"))
      refute fh["used_percent"] == 0
      assert is_nil(fh) or fh["used_percent"] == nil
    end

    test "unknown five_hour window requires confirmation" do
      snap =
        build_snapshot(%{
          windows: %{
            "items" => [
              %{"kind" => "five_hour", "state" => "unknown", "reason" => "vendor_error"},
              %{
                "kind" => "weekly",
                "state" => "observed",
                "used_percent" => 50.0,
                "reset_at" => "2026-09-14T00:00:00Z"
              }
            ]
          },
          capacity_state: "degraded",
          confidence: "medium",
          reason: "partial_outage"
        })

      assert {:ok, decision} =
               AdmissionEvaluation.evaluate(%{}, @default_candidate, snap, nil, now: @now)

      assert decision.result == :require_confirmation

      assert decision.reason_code in [
               "unknown_window_five_hour",
               "confidence_medium",
               "capacity_state_degraded"
             ]

      fh = Enum.find(decision.observation["windows"], &(&1["kind"] == "five_hour"))
      assert fh["state"] == "unknown"
      assert fh["used_percent"] == nil
      assert fh["reason"] == "vendor_error"
    end
  end

  describe "Stale and Future Observations" do
    test "stale observation requires confirmation" do
      # Observed 600s ago with 300s freshness -> expired at 13:55:00
      snap =
        build_snapshot(%{
          capacity_state: "degraded",
          confidence: "medium",
          reason: "stale_observation",
          observed_at: "2026-09-07T13:50:00Z",
          expires_at: "2026-09-07T13:55:00Z"
        })

      assert {:ok, decision} =
               AdmissionEvaluation.evaluate(%{}, @default_candidate, snap, nil, now: @now)

      assert decision.result == :require_confirmation
      assert decision.reason_code == "stale_observation"
      assert decision.observation["freshness"] == "stale"
    end

    test "future observation timestamp is treated as unknown and requires confirmation" do
      # Observed at 14:05:00, while now is 14:00:00
      future_snap = %{
        "contract_version" => 2,
        "snapshot_id" => Ecto.UUID.generate(),
        "capacity_state" => "unknown",
        "windows" => %{"items" => []},
        "freshness" => %{"max_age_seconds" => 300},
        "source" => %{
          "adapter_id" => "codex_app_server",
          "provider_id" => "codex",
          "invocation_mode" => "app_server",
          "event" => "explicit_read"
        },
        "scope" => "account:codex-default",
        "confidence" => "none",
        "support_tier" => "proactive",
        "compatibility_state" => "compatible",
        "observed_at" => "2026-09-07T14:05:00Z",
        "expires_at" => "2026-09-07T14:10:00Z",
        "reason" => "future_clock_drift",
        "extensions" => %{}
      }

      assert {:ok, decision} =
               AdmissionEvaluation.evaluate(%{}, @default_candidate, future_snap, nil, now: @now)

      assert decision.result == :require_confirmation
      assert decision.reason_code in ["future_observation", "unknown_capacity", "confidence_none"]
    end
  end

  describe "Support Tiers and Compatibility" do
    test "conservative_partial support tier requires confirmation" do
      candidate = %{@default_candidate | support_tier: :conservative_partial}

      snap =
        build_snapshot(%{
          support_tier: "conservative_partial",
          capacity_state: "degraded",
          confidence: "medium",
          reason: "conservative_monitor"
        })

      assert {:ok, decision} = AdmissionEvaluation.evaluate(%{}, candidate, snap, nil, now: @now)
      assert decision.result == :require_confirmation
      assert decision.reason_code == "support_tier_conservative_partial"
    end

    test "reactive_only support tier requires confirmation" do
      candidate = %{@default_candidate | support_tier: :reactive_only}

      snap =
        build_snapshot(%{
          support_tier: "reactive_only",
          capacity_state: "degraded",
          confidence: "low",
          reason: "reactive_monitor"
        })

      assert {:ok, decision} = AdmissionEvaluation.evaluate(%{}, candidate, snap, nil, now: @now)
      assert decision.result == :require_confirmation
      assert decision.reason_code == "support_tier_reactive_only"
    end

    test "unsupported tier is rejected permanently" do
      candidate = %{@default_candidate | support_tier: :unsupported}

      assert {:ok, decision} = AdmissionEvaluation.evaluate(%{}, candidate, nil, nil, now: @now)
      assert decision.result == :reject
      assert decision.reason_code == "unsupported_tier"
    end

    test "incompatible CLI is rejected permanently" do
      candidate = %{@default_candidate | compatibility_state: :incompatible}
      snap = build_snapshot(%{})

      assert {:ok, decision} = AdmissionEvaluation.evaluate(%{}, candidate, snap, nil, now: @now)
      assert decision.result == :reject
      assert decision.reason_code == "incompatible_cli"
    end

    test "degraded compatibility requires confirmation" do
      candidate = %{@default_candidate | compatibility_state: :degraded}

      snap =
        build_snapshot(%{
          compatibility_state: "degraded",
          capacity_state: "degraded",
          confidence: "medium",
          reason: "degraded_cli"
        })

      assert {:ok, decision} = AdmissionEvaluation.evaluate(%{}, candidate, snap, nil, now: @now)
      assert decision.result == :require_confirmation

      assert decision.reason_code in [
               "degraded_compatibility",
               "capacity_state_degraded",
               "confidence_medium"
             ]
    end
  end

  describe "Unbypassable Constraints (Cannot Be Overridden by Confirmation)" do
    @valid_override %{
      confirmed_by: "operator:alice",
      confirmed_at: "2026-09-07T14:00:00Z",
      intent: "manual_override",
      target_provider_id: "codex",
      target_scope: "account:codex-default"
    }

    test "unsupported capability cannot be bypassed by manual confirmation" do
      req = %{
        requested_capability: "unsupported_distributed_gpu",
        override: @valid_override
      }

      assert {:ok, decision} =
               AdmissionEvaluation.evaluate(req, @default_candidate, nil, nil, now: @now)

      assert decision.result == :reject
      assert decision.reason_code == "unsupported_capability"
    end

    test "incompatible CLI cannot be bypassed by manual confirmation" do
      candidate = %{@default_candidate | compatibility_state: :incompatible}
      req = %{override: @valid_override}

      assert {:ok, decision} = AdmissionEvaluation.evaluate(req, candidate, nil, nil, now: @now)
      assert decision.result == :reject
      assert decision.reason_code == "incompatible_cli"
    end

    test "scope mismatch cannot be bypassed by manual confirmation" do
      req = %{
        scope: "account:different-scope",
        override: %{@valid_override | target_scope: "account:different-scope"}
      }

      assert {:ok, decision} =
               AdmissionEvaluation.evaluate(req, @default_candidate, nil, nil, now: @now)

      assert decision.result == :reject
      assert decision.reason_code == "scope_mismatch"
    end

    test "active occupancy cannot be bypassed by manual confirmation" do
      req = %{override: @valid_override}
      snap = build_snapshot(%{})

      assert {:ok, decision} =
               AdmissionEvaluation.evaluate(req, @default_candidate, snap, nil,
                 now: @now,
                 occupancy: true
               )

      assert decision.result == :defer_until
      assert decision.reason_code == "scope_occupied"
      assert decision.reobservation_required == true
    end

    test "known reserve breach cannot be bypassed by manual confirmation" do
      snap =
        build_snapshot(%{
          windows: %{
            "items" => [
              %{
                "kind" => "five_hour",
                "state" => "observed",
                "used_percent" => 85.0,
                "reset_at" => "2026-09-07T18:00:00Z"
              },
              %{
                "kind" => "weekly",
                "state" => "observed",
                "used_percent" => 50.0,
                "reset_at" => "2026-09-14T00:00:00Z"
              }
            ]
          }
        })

      req = %{override: @valid_override}

      assert {:ok, decision} =
               AdmissionEvaluation.evaluate(req, @default_candidate, snap, nil, now: @now)

      assert decision.result == :defer_until
      assert decision.reason_code == "reserve_breach_five_hour"
      assert String.contains?(decision.explanation, "cannot bypass reserve breach")
    end

    test "hard quota block (provider refusal) cannot be bypassed by manual confirmation" do
      refusal_snap = %{
        "contract_version" => 2,
        "snapshot_id" => Ecto.UUID.generate(),
        "capacity_state" => "refused",
        "windows" => %{"items" => []},
        "freshness" => %{"max_age_seconds" => 300},
        "source" => %{
          "adapter_id" => "codex_app_server",
          "provider_id" => "codex",
          "invocation_mode" => "app_server",
          "event" => "explicit_read"
        },
        "scope" => "account:codex-default",
        "confidence" => "medium",
        "support_tier" => "proactive",
        "compatibility_state" => "compatible",
        "reason" => "rate_limit_exceeded",
        "extensions" => %{}
      }

      req = %{override: @valid_override}

      assert {:ok, decision} =
               AdmissionEvaluation.evaluate(req, @default_candidate, refusal_snap, nil, now: @now)

      assert decision.result == :defer_until
      assert String.contains?(decision.explanation, "cannot bypass hard quota block")
    end
  end

  describe "Allowed Override Confirmations" do
    test "valid attributable confirmation admits unknown capacity with honest explanation" do
      req = %{
        override: %{
          confirmed_by: "operator:alice",
          confirmed_at: "2026-09-07T14:00:00Z",
          intent: "emergency_manual_run",
          target_provider_id: "codex",
          target_scope: "account:codex-default"
        }
      }

      assert {:ok, decision} =
               AdmissionEvaluation.evaluate(req, @default_candidate, nil, nil, now: @now)

      assert decision.result == :admit
      assert decision.reason_code == "confirmed_unknown_capacity"
      assert String.contains?(decision.explanation, "not automatically safe")
      assert String.contains?(decision.explanation, "operator:alice")
      assert decision.override["valid"] == true
    end

    test "valid confirmation admits stale observation" do
      snap =
        build_snapshot(%{
          capacity_state: "degraded",
          confidence: "medium",
          reason: "stale_observation",
          observed_at: "2026-09-07T13:50:00Z",
          expires_at: "2026-09-07T13:55:00Z"
        })

      req = %{
        override: %{
          confirmed_by: "operator:alice",
          confirmed_at: "2026-09-07T14:00:00Z",
          intent: "manual_stale_bypass",
          target_provider_id: "codex",
          target_scope: "account:codex-default"
        }
      }

      assert {:ok, decision} =
               AdmissionEvaluation.evaluate(req, @default_candidate, snap, nil, now: @now)

      assert decision.result == :admit
      assert decision.reason_code == "confirmed_stale_observation"
      assert String.contains?(decision.explanation, "not automatically safe")
    end

    test "confirmation for different provider is rejected and cannot authorize target candidate" do
      req = %{
        override: %{
          confirmed_by: "operator:alice",
          intent: "manual_run",
          target_provider_id: "claude",
          target_scope: "account:codex-default"
        }
      }

      assert {:ok, decision} =
               AdmissionEvaluation.evaluate(req, @default_candidate, nil, nil, now: @now)

      assert decision.result == :require_confirmation
      assert decision.reason_code == "confirmation_invalid_provider_mismatch"
      assert decision.override["valid"] == false
      assert decision.override["reason"] == "provider_mismatch"
    end

    test "unattributed confirmation (blank confirmed_by) is rejected" do
      req = %{
        override: %{
          confirmed_by: "   ",
          intent: "manual_run",
          target_provider_id: "codex",
          target_scope: "account:codex-default"
        }
      }

      assert {:ok, decision} =
               AdmissionEvaluation.evaluate(req, @default_candidate, nil, nil, now: @now)

      assert decision.result == :require_confirmation
      assert decision.reason_code == "confirmation_invalid_unattributed"
      assert decision.override["valid"] == false
    end
  end

  describe "Past Reset Timestamps and Delayed Recheck" do
    test "past reset timestamp does not cause immediate loop; schedules delayed recheck" do
      # 5-hour window breached at 85%, but reset_at is 13:30:00 (in the past relative to now 14:00:00)
      snap =
        build_snapshot(%{
          windows: %{
            "items" => [
              %{
                "kind" => "five_hour",
                "state" => "observed",
                "used_percent" => 85.0,
                "reset_at" => "2026-09-07T13:30:00Z"
              },
              %{
                "kind" => "weekly",
                "state" => "observed",
                "used_percent" => 50.0,
                "reset_at" => "2026-09-14T00:00:00Z"
              }
            ]
          }
        })

      policy = AdmissionPolicy.default()

      assert {:ok, decision} =
               AdmissionEvaluation.evaluate(%{}, @default_candidate, snap, policy, now: @now)

      assert decision.result == :defer_until
      assert decision.reason_code == "past_reset_delayed_recheck"
      # defer_until is now + 60s, NOT in the past
      assert decision.defer_until == ~U[2026-09-07 14:01:00.000000Z]
      assert decision.reobservation_required == true
    end

    test "future reset timestamp defers until that exact reset" do
      future_reset = "2026-09-07T16:30:00Z"

      snap =
        build_snapshot(%{
          windows: %{
            "items" => [
              %{
                "kind" => "five_hour",
                "state" => "observed",
                "used_percent" => 85.0,
                "reset_at" => future_reset
              },
              %{
                "kind" => "weekly",
                "state" => "observed",
                "used_percent" => 50.0,
                "reset_at" => "2026-09-14T00:00:00Z"
              }
            ]
          }
        })

      assert {:ok, decision} =
               AdmissionEvaluation.evaluate(%{}, @default_candidate, snap, nil, now: @now)

      assert decision.result == :defer_until
      assert decision.reason_code == "reserve_breach_five_hour"
      assert decision.defer_until == ~U[2026-09-07 16:30:00Z]
      assert decision.reobservation_required == true
    end
  end

  describe "evaluate_candidates/5 Multi-Candidate Selection" do
    test "evaluates candidates in policy priority order and selects best" do
      claude_candidate = %{
        provider_id: "claude",
        adapter_id: "claude_headless",
        support_tier: :proactive,
        compatibility_state: :compatible,
        scope: "account:claude-default",
        capabilities: ["supervised_execution"]
      }

      # Codex is breached (85% five-hour), Claude is healthy (40% five-hour)
      codex_snap =
        build_snapshot(%{
          windows: %{
            "items" => [
              %{
                "kind" => "five_hour",
                "state" => "observed",
                "used_percent" => 85.0,
                "reset_at" => "2026-09-07T18:00:00Z"
              },
              %{
                "kind" => "weekly",
                "state" => "observed",
                "used_percent" => 50.0,
                "reset_at" => "2026-09-14T00:00:00Z"
              }
            ]
          }
        })

      claude_snap =
        build_snapshot(%{
          scope: "account:claude-default",
          source: %{
            "adapter_id" => "claude_headless",
            "provider_id" => "claude",
            "invocation_mode" => "headless",
            "event" => "explicit_read"
          },
          windows: %{
            "items" => [
              %{
                "kind" => "five_hour",
                "state" => "observed",
                "used_percent" => 40.0,
                "reset_at" => "2026-09-07T18:00:00Z"
              },
              %{
                "kind" => "weekly",
                "state" => "observed",
                "used_percent" => 40.0,
                "reset_at" => "2026-09-14T00:00:00Z"
              }
            ]
          }
        })

      snapshots = %{"codex" => codex_snap, "claude" => claude_snap}
      candidates = [@default_candidate, claude_candidate]

      assert {:ok, %{selected: selected, all: all_decisions}} =
               AdmissionEvaluation.evaluate_candidates(%{}, candidates, snapshots, nil, now: @now)

      assert length(all_decisions) == 2
      # Claude is admitted, Codex is deferred -> Selected is Claude!
      assert selected.candidate.provider_id == "claude"
      assert selected.result == :admit
    end
  end

  describe "Durable Append & Replay Integration" do
    test "appends admission.decided event to trajectory and replays cleanly" do
      goal = insert_goal()
      goal_id = goal.id

      # Create a parent goal in the trajectory
      {:ok, _goal_event} =
        Trajectory.append(goal_id, %{
          "type" => "goal.created",
          "schema_version" => 1,
          "actor" => "test_operator",
          "payload" => %{"title" => "Iteration 5 Admission Test"}
        })

      snap = build_snapshot(%{})
      decision_id = Ecto.UUID.generate()
      run_id = Ecto.UUID.generate()

      {:ok, decision} =
        AdmissionEvaluation.evaluate(
          %{run_id: run_id, goal_id: goal_id},
          @default_candidate,
          snap,
          nil,
          now: @now,
          decision_id: decision_id
        )

      payload = AdmissionDecision.to_payload(decision)

      # Append untrusted input
      assert {:ok, persisted_event} =
               Trajectory.append(
                 goal_id,
                 %{
                   "type" => "admission.decided",
                   "schema_version" => 1,
                   "actor" => "cobbler_admission",
                   "payload" => payload
                 }
               )

      assert persisted_event.type == "admission.decided"
      assert persisted_event.sequence == 2
      assert persisted_event.payload["run_id"] == run_id
      assert persisted_event.payload["decision_id"] == decision_id
      assert persisted_event.payload["result"] == "admit"

      # Replay the trajectory and ensure event validates
      assert {:ok, events} = Trajectory.replay(goal_id)
      assert length(events) == 2

      replayed_admission = Enum.find(events, &(&1.type == "admission.decided"))
      assert replayed_admission.payload["decision_id"] == decision_id
      assert replayed_admission.payload["reason_code"] == "automatic_admission_eligible"
      assert replayed_admission.payload["result"] == "admit"
    end
  end

  defp insert_goal do
    %Goal{}
    |> Goal.changeset(%{"title" => "A goal"})
    |> Ecto.Changeset.put_change(:owner_id, Ecto.UUID.generate())
    |> Repo.insert!()
  end
end
