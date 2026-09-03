defmodule Shoestring.Harness.CapacityTest do
  use ExUnit.Case, async: true

  alias Shoestring.Harness.{Capacity, CapacitySnapshot}
  alias Shoestring.Harness.Capacity.Fixtures, as: CapacityFixtures

  @evaluation_time ~U[2026-08-29 04:38:25Z]
  @claude_eval_time ~U[2026-08-29 07:34:25Z]

  describe "compatibility/3" do
    test "evaluates supported Codex stdio with tested version" do
      result = Capacity.compatibility(:codex, :app_server_stdio, "0.150.1")

      assert result.provider == :codex
      assert result.invocation_mode == :app_server_stdio
      assert result.support_tier == :proactive
      assert result.compatibility_state == :compatible
      assert result.version == "0.150.1"
      assert result.reason == nil
    end

    test "evaluates supported Claude statusLine with tested version" do
      result = Capacity.compatibility(:claude, :interactive_status_line, "2.1.251")

      assert result.provider == :claude
      assert result.invocation_mode == :interactive_status_line
      assert result.support_tier == :conservative_partial
      assert result.compatibility_state == :compatible
      assert result.version == "2.1.251"
      assert result.reason == nil
    end

    test "evaluates untested Codex version drift as degraded" do
      result = Capacity.compatibility(:codex, :app_server_stdio, "0.151.0")

      assert result.support_tier == :proactive
      assert result.compatibility_state == :degraded
      assert result.version == "0.151.0"
      assert result.reason == "untested_cli_version: 0.151.0"
    end

    test "evaluates untested Claude version drift as degraded" do
      result = Capacity.compatibility(:claude, :interactive_status_line, "2.2.0")

      assert result.support_tier == :conservative_partial
      assert result.compatibility_state == :degraded
      assert result.version == "2.2.0"
      assert result.reason == "untested_cli_version: 2.2.0"
    end

    test "evaluates missing version as degraded" do
      result = Capacity.compatibility(:codex, :app_server_stdio, nil)

      assert result.compatibility_state == :degraded
      assert result.reason == "untested_cli_version: unknown"
    end

    test "evaluates Claude headless modes as incompatible and unsupported" do
      json_res = Capacity.compatibility(:claude, :headless_json, "2.1.251")
      assert json_res.support_tier == :unsupported
      assert json_res.compatibility_state == :incompatible
      assert json_res.reason =~ "Claude headless -p --output-format json"

      stream_res = Capacity.compatibility(:claude, :headless_stream_json, "2.1.251")
      assert stream_res.support_tier == :unsupported
      assert stream_res.compatibility_state == :incompatible

      scrape_res = Capacity.compatibility(:claude, :terminal_scrape)
      assert scrape_res.support_tier == :unsupported
      assert scrape_res.compatibility_state == :incompatible
    end

    test "evaluates unsupported provider and mode" do
      prov_res = Capacity.compatibility(:unknown_provider, :stdio)
      assert prov_res.support_tier == :unsupported
      assert prov_res.compatibility_state == :incompatible
      assert prov_res.reason =~ "unsupported_provider"

      mode_res = Capacity.compatibility(:codex, :unknown_mode)
      assert mode_res.support_tier == :unsupported
      assert mode_res.compatibility_state == :incompatible
      assert mode_res.reason =~ "unsupported_mode"
    end
  end

  describe "normalize/4 supported versions and normal windows" do
    test "normalizes supported Codex normal read into an eligible observed snapshot" do
      fixture = CapacityFixtures.load_fixture!("codex/normal-read.json")

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :codex,
                 :app_server_stdio,
                 fixture,
                 version: "0.150.1",
                 now: @evaluation_time
               )

      assert snapshot.version == 2
      assert snapshot.capacity_state == :observed
      assert snapshot.support_tier == :proactive
      assert snapshot.compatibility_state == :compatible
      assert snapshot.confidence == :high
      assert snapshot.reason == nil
      assert snapshot.source.provider_id == "codex"
      assert snapshot.source.invocation_mode == "app_server_stdio"
      assert snapshot.source.event == :explicit_read

      [primary, secondary] = snapshot.windows
      assert primary.kind == "primary"
      assert primary.state == :observed
      assert primary.used_percent == 13
      assert %DateTime{} = primary.reset_at

      assert secondary.kind == "secondary"
      assert secondary.state == :observed
      assert secondary.used_percent == 16
      assert %DateTime{} = secondary.reset_at

      assert CapacitySnapshot.freshness(snapshot, @evaluation_time) == :fresh
      assert CapacitySnapshot.eligible?(snapshot, @evaluation_time)
    end

    test "normalizes supported Codex sparse update notification into an observed snapshot" do
      fixture = CapacityFixtures.load_fixture!("codex/sparse-update-live.json")

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :codex,
                 :app_server_stdio,
                 fixture,
                 version: "0.150.1",
                 now: @evaluation_time
               )

      assert snapshot.capacity_state == :observed
      assert snapshot.source.event == :update_notification
      assert [primary, secondary] = snapshot.windows
      assert primary.used_percent == 13
      assert secondary.used_percent == 16
    end

    test "normalizes supported Claude statusLine callback into a conservative/partial degraded snapshot" do
      fixture = CapacityFixtures.load_fixture!("claude/status-line-single-live.json")

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :claude,
                 :interactive_status_line,
                 fixture,
                 version: "2.1.251",
                 now: @claude_eval_time
               )

      assert snapshot.version == 2
      assert snapshot.capacity_state == :degraded
      assert snapshot.support_tier == :conservative_partial
      assert snapshot.compatibility_state == :compatible
      assert snapshot.confidence == :medium
      assert snapshot.reason == "conservative_partial_observation"
      assert snapshot.source.provider_id == "claude"
      assert snapshot.source.invocation_mode == "interactive_status_line"
      assert snapshot.source.event == :status_line_input

      [five_hour, seven_day] = snapshot.windows
      assert five_hour.kind == "five_hour"
      assert five_hour.state == :observed
      assert five_hour.used_percent == 25
      assert %DateTime{} = five_hour.reset_at

      assert seven_day.kind == "seven_day"
      assert seven_day.state == :observed
      assert seven_day.used_percent == 94
      assert %DateTime{} = seven_day.reset_at

      # Conservative/partial sources are never eligible for automatic proactive admission
      refute CapacitySnapshot.eligible?(snapshot, @claude_eval_time)
    end
  end

  describe "normalize/4 untested version drift" do
    test "Codex observation on untested version degrades compatibility and capacity" do
      fixture = CapacityFixtures.load_fixture!("codex/normal-read.json")

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :codex,
                 :app_server_stdio,
                 fixture,
                 version: "0.151.0",
                 now: @evaluation_time
               )

      assert snapshot.capacity_state == :degraded
      assert snapshot.compatibility_state == :degraded
      assert snapshot.confidence == :medium
      assert snapshot.reason == "untested_cli_version: 0.151.0"

      # Windows remain honest and preserved, but snapshot is ineligible
      assert [primary, secondary] = snapshot.windows
      assert primary.state == :observed
      assert primary.used_percent == 13
      assert secondary.state == :observed
      assert secondary.used_percent == 16
      refute CapacitySnapshot.eligible?(snapshot, @evaluation_time)
    end

    test "Claude observation on untested version degrades compatibility" do
      fixture = CapacityFixtures.load_fixture!("claude/normal-official-shape.json")

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :claude,
                 :interactive_status_line,
                 fixture,
                 version: "2.2.0",
                 now: ~U[2026-08-29 04:30:10Z]
               )

      assert snapshot.capacity_state == :degraded
      assert snapshot.compatibility_state == :degraded
      assert snapshot.reason == "untested_cli_version: 2.2.0"
    end
  end

  describe "normalize/4 additive unknown fields" do
    test "Codex ignores extra unknown JSON-RPC fields and normalizes successfully" do
      payload = %{
        "id" => 10,
        "jsonrpc" => "2.0",
        "unexpectedRootField" => %{"deep" => true},
        "futureTelemetry" => [1, 2, 3],
        "result" => %{
          "extraResultMeta" => "safe_meta_string",
          "rateLimits" => %{
            "primary" => %{
              "usedPercent" => 15,
              "windowDurationMins" => 300,
              "resetsAt" => 1_787_994_541,
              "additiveWindowFlag" => true
            },
            "secondary" => %{
              "usedPercent" => 20,
              "windowDurationMins" => 10080,
              "resetsAt" => 1_788_494_929,
              "anotherNewField" => "hello"
            },
            "brandNewLimitKind" => %{"info" => 123}
          }
        }
      }

      observation = %{
        "captured_at" => "2026-08-29T04:38:16.163Z",
        "payload" => payload
      }

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :codex,
                 :app_server_stdio,
                 observation,
                 version: "0.150.1",
                 now: @evaluation_time
               )

      assert snapshot.capacity_state == :observed
      assert snapshot.compatibility_state == :compatible
      [primary, secondary] = snapshot.windows
      assert primary.used_percent == 15
      assert secondary.used_percent == 20
    end

    test "Claude ignores additive fields in status-line payload" do
      payload = %{
        "version" => "2.1.251",
        "futureTopLevelMetric" => 42,
        "rate_limits" => %{
          "five_hour" => %{
            "used_percentage" => 10,
            "resets_at" => 1_787_994_000,
            "unknown_subfield" => "ignored"
          },
          "seven_day" => %{
            "used_percentage" => 40,
            "resets_at" => 1_788_033_600
          },
          "new_provider_window" => %{
            "some_key" => 123
          }
        }
      }

      observation = %{
        "captured_at" => "2026-08-29T07:34:19.504Z",
        "payload" => payload
      }

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :claude,
                 :interactive_status_line,
                 observation,
                 version: "2.1.251",
                 now: @claude_eval_time
               )

      assert snapshot.capacity_state == :degraded
      [five_hour, seven_day] = snapshot.windows
      assert five_hour.used_percent == 10
      assert seven_day.used_percent == 40
    end
  end

  describe "normalize/4 missing required semantic fields" do
    test "Codex missing rateLimits object fails closed as unknown" do
      observation = %{
        "captured_at" => "2026-08-29T04:38:16.163Z",
        "payload" => %{"id" => 1, "result" => %{}}
      }

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :codex,
                 :app_server_stdio,
                 observation,
                 version: "0.150.1",
                 now: @evaluation_time
               )

      assert snapshot.capacity_state == :unknown
      assert snapshot.confidence == :none
      assert snapshot.reason == "missing_rate_limits"
      assert Enum.all?(snapshot.windows, &(&1.state == :unknown))
    end

    test "Codex missing secondary window degrades gracefully without fabricating zero" do
      fixture = CapacityFixtures.load_fixture!("codex/partial-missing-secondary.json")

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :codex,
                 :app_server_stdio,
                 fixture,
                 version: "0.150.1",
                 now: ~U[2026-08-29 04:30:45Z]
               )

      assert snapshot.capacity_state == :degraded
      assert snapshot.confidence == :medium
      assert snapshot.reason == "missing_window: secondary"

      [primary, secondary] = snapshot.windows
      assert primary.kind == "primary"
      assert primary.state == :observed
      assert primary.used_percent == 12

      assert secondary.kind == "secondary"
      assert secondary.state == :unknown
      assert secondary.reason == "missing_window: secondary"
      refute Map.has_key?(secondary, :used_percent)
    end

    test "Claude rate limits absent before first response degrades to unknown" do
      fixture = CapacityFixtures.load_fixture!("claude/missing-before-response.json")

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :claude,
                 :interactive_status_line,
                 fixture,
                 version: "2.1.251",
                 now: ~U[2026-08-29 07:34:25Z]
               )

      assert snapshot.capacity_state == :unknown
      assert snapshot.confidence == :none

      assert snapshot.reason ==
               "rate_limits_absent_before_first_response_or_unsupported_subscription"
    end

    test "Claude partial official shape normalizes with single observed window" do
      fixture = CapacityFixtures.load_fixture!("claude/partial-official-shape.json")

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :claude,
                 :interactive_status_line,
                 fixture,
                 version: "2.1.251",
                 now: ~U[2026-08-29 04:30:10Z]
               )

      assert snapshot.capacity_state == :degraded
      assert snapshot.confidence == :medium
      assert snapshot.reason == "partial_window_observation"

      [five_hour, seven_day] = snapshot.windows
      assert five_hour.kind == "five_hour"
      assert five_hour.state == :observed
      assert five_hour.used_percent == 23.5

      assert seven_day.kind == "seven_day"
      assert seven_day.state == :unknown
    end
  end

  describe "normalize/4 malformed values" do
    test "Codex non-numeric or out-of-bounds percentage fails closed as unknown" do
      bad_string = %{
        "captured_at" => "2026-08-29T04:38:16.163Z",
        "payload" => %{
          "result" => %{
            "rateLimits" => %{
              "primary" => %{"usedPercent" => "13", "windowDurationMins" => 300},
              "secondary" => %{"usedPercent" => 16, "windowDurationMins" => 10080}
            }
          }
        }
      }

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :codex,
                 :app_server_stdio,
                 bad_string,
                 version: "0.150.1",
                 now: @evaluation_time
               )

      assert snapshot.capacity_state == :unknown
      assert snapshot.confidence == :none
      assert snapshot.reason == "malformed_window_value"
      assert Enum.all?(snapshot.windows, &(&1.state == :unknown))

      bad_negative = %{
        "captured_at" => "2026-08-29T04:38:16.163Z",
        "payload" => %{
          "result" => %{
            "rateLimits" => %{
              "primary" => %{"usedPercent" => -1},
              "secondary" => %{"usedPercent" => 16}
            }
          }
        }
      }

      assert {:ok, snapshot2} =
               Capacity.normalize(
                 :codex,
                 :app_server_stdio,
                 bad_negative,
                 version: "0.150.1",
                 now: @evaluation_time
               )

      assert snapshot2.capacity_state == :unknown
      assert snapshot2.reason == "malformed_window_value"
    end

    test "Claude malformed window replay yields unknown without zero usage" do
      fixture = CapacityFixtures.load_fixture!("claude/malformed-replay.json")

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :claude,
                 :interactive_status_line,
                 fixture,
                 version: "2.1.251",
                 now: ~U[2026-08-29 07:34:25Z]
               )

      assert snapshot.capacity_state == :unknown
      assert snapshot.confidence == :none
      assert snapshot.reason == "malformed_window_value"
    end
  end

  describe "normalize/4 unsupported modes and providers" do
    test "Claude headless JSON is marked unknown, incompatible, and unsupported" do
      fixture = CapacityFixtures.load_fixture!("claude/auth-preflight-live.json")

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :claude,
                 :headless_json,
                 fixture,
                 version: "2.1.251",
                 now: ~U[2026-08-29 06:23:00Z]
               )

      assert snapshot.capacity_state == :unknown
      assert snapshot.support_tier == :unsupported
      assert snapshot.compatibility_state == :incompatible
      assert snapshot.confidence == :none
      assert snapshot.reason =~ "headless -p --output-format json"
    end

    test "Claude terminal scraping is marked incompatible and unsupported" do
      assert {:ok, snapshot} =
               Capacity.normalize(
                 :claude,
                 :terminal_scrape,
                 %{"captured_at" => "2026-08-29T06:23:00Z", "payload" => %{}},
                 now: ~U[2026-08-29 06:23:00Z]
               )

      assert snapshot.support_tier == :unsupported
      assert snapshot.compatibility_state == :incompatible
    end

    test "unsupported provider produces incompatible unknown snapshot" do
      assert {:ok, snapshot} =
               Capacity.normalize(
                 :mystery_provider,
                 :stdio,
                 %{},
                 now: @evaluation_time
               )

      assert snapshot.capacity_state == :unknown
      assert snapshot.compatibility_state == :incompatible
      assert snapshot.reason =~ "unsupported_provider"
    end
  end

  describe "normalize/4 refusal signals" do
    test "Codex rate-limit reached indicator produces refused snapshot" do
      fixture = CapacityFixtures.load_fixture!("codex/refusal-unverified.json")

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :codex,
                 :app_server_stdio,
                 fixture,
                 version: "0.150.1",
                 now: ~U[2026-08-29 04:30:10Z]
               )

      assert snapshot.capacity_state == :refused
      assert snapshot.confidence == :low
      assert snapshot.reason == "provider_reported_rate_limit_reached"
      assert Enum.all?(snapshot.windows, &(&1.state == :unknown))
      assert snapshot.extensions["codex:rate_limit_reached_type"] == "rate_limit_reached"
    end

    test "Claude refusal subtype produces refused snapshot" do
      fixture = CapacityFixtures.load_fixture!("claude/refusal-unverified.json")

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :claude,
                 :interactive_status_line,
                 fixture,
                 version: "2.1.251",
                 now: ~U[2026-08-29 07:34:25Z]
               )

      assert snapshot.capacity_state == :refused
      assert snapshot.confidence == :low
      assert snapshot.reason == "cli_reported_rate_limit_refusal_without_capacity_snapshot"
    end
  end

  describe "normalize/4 timestamps and freshness" do
    test "future timestamp fails closed as unknown" do
      future_obs = %{
        "captured_at" => "2026-08-29T04:40:00.000Z",
        "payload" => %{
          "result" => %{
            "rateLimits" => %{
              "primary" => %{"usedPercent" => 10},
              "secondary" => %{"usedPercent" => 20}
            }
          }
        }
      }

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :codex,
                 :app_server_stdio,
                 future_obs,
                 version: "0.150.1",
                 now: ~U[2026-08-29 04:38:00Z]
               )

      assert snapshot.capacity_state == :unknown
      assert snapshot.confidence == :none
      assert snapshot.reason == "missing_or_invalid_observation_timestamp"
    end

    test "stale observation degrades gracefully with low confidence" do
      fixture = CapacityFixtures.load_fixture!("codex/stale-replay.json")

      # Evaluating at a time > 300s after the 04:30:00 captured_at
      eval_time = ~U[2026-08-29 05:30:00Z]

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :codex,
                 :app_server_stdio,
                 fixture,
                 version: "0.150.1",
                 now: eval_time
               )

      assert snapshot.capacity_state == :degraded
      assert snapshot.confidence == :low
      assert snapshot.reason == "stale_observation"
      assert CapacitySnapshot.freshness(snapshot, eval_time) == :stale
    end
  end

  describe "preserve_last_known/3" do
    setup do
      fixture = CapacityFixtures.load_fixture!("codex/normal-read.json")

      {:ok, valid_snapshot} =
        Capacity.normalize(
          :codex,
          :app_server_stdio,
          fixture,
          version: "0.150.1",
          now: @evaluation_time
        )

      %{valid_snapshot: valid_snapshot}
    end

    test "preserves last-known observation windows when parse error occurs", %{
      valid_snapshot: last_known
    } do
      malformed_obs = %{
        "captured_at" => "2026-08-29T04:38:20.000Z",
        "payload" => %{
          "result" => %{"rateLimits" => %{"primary" => %{"usedPercent" => "invalid"}}}
        }
      }

      assert {:ok, preserved} =
               Capacity.normalize(
                 :codex,
                 :app_server_stdio,
                 malformed_obs,
                 version: "0.150.1",
                 now: @evaluation_time,
                 last_known_snapshot: last_known
               )

      # Capacity is degraded, not fabricated zero usage
      assert preserved.capacity_state == :degraded
      assert preserved.compatibility_state == :degraded
      assert preserved.confidence == :low
      assert preserved.reason =~ "preserving last-known observation"

      # Windows from last known are preserved intact
      assert [primary, secondary] = preserved.windows
      assert primary.used_percent == 13
      assert secondary.used_percent == 16
      assert preserved.observed_at == last_known.observed_at
    end

    test "direct preserve_last_known/3 preserves windows and marks degraded", %{
      valid_snapshot: last_known
    } do
      assert {:ok, preserved} =
               Capacity.preserve_last_known(
                 last_known,
                 "stdio_transport_disconnected",
                 now: @evaluation_time
               )

      assert preserved.capacity_state == :degraded
      assert preserved.confidence == :low
      assert preserved.reason =~ "stdio_transport_disconnected"
      assert [primary, _secondary] = preserved.windows
      assert primary.used_percent == 13
    end
  end

  describe "security and bounded diagnostics" do
    test "rejects observation containing secret patterns immediately" do
      secret_obs = %{
        "captured_at" => "2026-08-29T04:38:16.163Z",
        "payload" => %{
          "api_key" => "sk-12345678901234567890",
          "result" => %{"rateLimits" => %{}}
        }
      }

      assert {:error, :contains_secrets_or_forbidden_content} =
               Capacity.normalize(
                 :codex,
                 :app_server_stdio,
                 secret_obs,
                 version: "0.150.1",
                 now: @evaluation_time
               )
    end

    test "diagnostic reasons are bounded to 300 characters" do
      long_reason = String.duplicate("reason_string_", 30)

      compat = Capacity.compatibility(:codex, :app_server_stdio, long_reason)
      assert String.length(compat.reason) <= 300
    end
  end
end
