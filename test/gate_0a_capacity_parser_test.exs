Code.require_file("../tools/gate_0a/capacity_parser.exs", __DIR__)

defmodule Shoestring.Gate0ACapacityParserTest do
  use ExUnit.Case, async: true

  alias Shoestring.Gate0A.CapacityParser

  @evaluation_time ~U[2026-08-29 04:30:45Z]
  @latest_codex_evaluation_time ~U[2026-08-29 04:38:25Z]
  @fixture_root Path.expand("../plans/evidence/00a-capacity-feasibility/fixtures", __DIR__)

  test "parses a live Codex read with both rolling windows" do
    result = parse_fixture("codex/normal-read.json", :codex, @latest_codex_evaluation_time)

    assert result.state == "observed"
    assert result.availability == "available"
    assert result.confidence == "high"
    assert result.source_event == "explicit_read"
    assert result.freshness.state == "fresh"
    assert result.windows.primary.used_percent == 13
    assert result.windows.primary.remaining_percent == 87
    assert result.windows.secondary.window_duration_minutes == 10080
    assert result.details.reset_credit_count == 1
    assert result.details.reset_credit_detail_state == "present_redacted"
  end

  test "parses a sparse Codex update notification without treating absent fields as zero" do
    result = parse_fixture("codex/sparse-update-live.json", :codex, @latest_codex_evaluation_time)

    assert result.state == "observed"
    assert result.source_event == "update_notification"
    assert result.details.spend_control_reached == nil
    assert result.details.reset_credit_detail_state == "absent"
    assert result.windows.primary.used_percent == 13
    assert result.windows.secondary.used_percent == 16
  end

  test "missing Codex bucket is degraded and never becomes zero usage" do
    result = parse_fixture("codex/partial-missing-secondary.json", :codex)

    assert result.state == "degraded"
    assert result.availability == "available"
    assert result.confidence == "medium"
    assert result.windows.primary.used_percent == 12
    assert result.windows.secondary == nil
    refute result.windows.primary.used_percent == 0
  end

  test "stale Codex observations are degraded" do
    result = parse_fixture("codex/stale-replay.json", :codex)

    assert result.state == "degraded"
    assert result.confidence == "low"
    assert result.freshness.state == "stale"
    assert result.freshness.age_seconds >= 3600
  end

  test "malformed Codex values become unknown rather than zero usage" do
    result = parse_fixture("codex/malformed-replay.json", :codex)

    assert result.state == "unknown"
    assert result.availability == "unknown"
    assert result.confidence == "none"
    assert result.reason == "malformed_window_value"
    assert result.windows == %{}
  end

  test "Codex refusal signal is explicit but marked as unverified fixture evidence" do
    result = parse_fixture("codex/refusal-unverified.json", :codex)

    assert result.state == "refused"
    assert result.availability == "refused"
    assert result.reason == "provider_reported_rate_limit_reached"
  end

  test "Codex refusal survives malformed windows" do
    fixture = %{
      "captured_at" => "2026-08-29T04:30:00.000Z",
      "payload" => %{
        "result" => %{
          "rateLimits" => %{
            "primary" => %{"usedPercent" => "100"},
            "secondary" => %{"usedPercent" => :drifted},
            "rateLimitReachedType" => "rate_limit_reached"
          }
        }
      }
    }

    result = CapacityParser.parse(:codex, fixture, now: @evaluation_time)

    assert result.state == "refused"
    assert result.availability == "refused"
    assert result.windows == %{primary: nil, secondary: nil}
    assert result.details.rate_limit_reached_type == "rate_limit_reached"
    assert result.reason == "provider_reported_rate_limit_reached"
  end

  test "valid Codex windows without captured_at remain unknown" do
    fixture = %{
      "payload" => %{
        "result" => %{
          "rateLimits" => %{
            "primary" => %{"usedPercent" => 12},
            "secondary" => %{"usedPercent" => 16}
          }
        }
      }
    }

    result = CapacityParser.parse(:codex, fixture, now: @evaluation_time)

    assert result.state == "unknown"
    assert result.availability == "unknown"
    assert result.confidence == "none"
    assert result.freshness.state == "unknown"
    assert result.reason == "missing_or_invalid_observation_timestamp"
  end

  test "valid Codex windows with an invalid captured_at remain unknown" do
    fixture = %{
      "captured_at" => "not-a-timestamp",
      "payload" => %{
        "result" => %{
          "rateLimits" => %{
            "primary" => %{"usedPercent" => 12},
            "secondary" => %{"usedPercent" => 16}
          }
        }
      }
    }

    result = CapacityParser.parse(:codex, fixture, now: @evaluation_time)

    assert result.state == "unknown"
    assert result.availability == "unknown"
    assert result.confidence == "none"
    assert result.freshness.state == "unknown"
    assert result.reason == "missing_or_invalid_observation_timestamp"
  end

  test "future Codex observations fail closed as freshness unknown" do
    fixture = %{
      "captured_at" => "2026-08-29T04:31:00.001Z",
      "payload" => %{
        "result" => %{
          "rateLimits" => %{
            "primary" => %{"usedPercent" => 12},
            "secondary" => %{"usedPercent" => 16}
          }
        }
      }
    }

    result = CapacityParser.parse(:codex, fixture, now: ~U[2026-08-29 04:30:45Z])

    assert result.state == "unknown"
    assert result.availability == "unknown"
    assert result.confidence == "none"
    assert result.freshness == %{state: "unknown", age_seconds: nil, max_age_seconds: 300}
    assert result.reason == "missing_or_invalid_observation_timestamp"
  end

  test "no valid windows takes precedence over a missing timestamp reason" do
    fixture = %{
      "payload" => %{
        "result" => %{
          "rateLimits" => %{"primary" => nil, "secondary" => nil}
        }
      }
    }

    result = CapacityParser.parse(:codex, fixture, now: @evaluation_time)

    assert result.state == "unknown"
    assert result.reason == "no_valid_windows"
  end

  test "Claude status-line documentation shape parses both windows" do
    result = parse_fixture("claude/normal-official-shape.json", :claude)

    assert result.state == "observed"
    assert result.availability == "available"
    assert result.confidence == "high"
    assert result.source_event == "status_line_input"
    assert result.windows.five_hour.used_percent == 23.5
    assert result.windows.five_hour.remaining_percent == 76.5
    assert result.windows.seven_day.resets_at == 1_738_857_600
    assert result.windows.spend_limit == nil
  end

  test "Claude independent window absence is degraded and not zero" do
    result = parse_fixture("claude/partial-official-shape.json", :claude)

    assert result.state == "degraded"
    assert result.confidence == "medium"
    assert result.windows.five_hour.used_percent == 23.5
    assert result.windows.seven_day == nil
    refute result.windows.five_hour.used_percent == 0
  end

  test "Claude stale replay parses as degraded with low confidence" do
    result = parse_fixture("claude/stale-replay.json", :claude)

    assert result.state == "degraded"
    assert result.availability == "available"
    assert result.confidence == "low"
    assert result.freshness.state == "stale"
    assert result.freshness.age_seconds >= 3600
  end

  test "live Claude status-line callback parses both capacity windows" do
    result =
      parse_fixture(
        "claude/status-line-single-live.json",
        :claude,
        ~U[2026-08-29 07:34:20Z]
      )

    assert result.state == "observed"
    assert result.availability == "available"
    assert result.confidence == "high"
    assert result.source_event == "status_line_input"
    assert result.freshness.state == "fresh"
    assert result.observed_at == "2026-08-29T07:34:19.504Z"
    assert result.windows.five_hour.used_percent == 25
    assert result.windows.five_hour.remaining_percent == 75
    assert result.windows.seven_day.used_percent == 94
    assert result.windows.seven_day.remaining_percent == 6
    assert result.windows.spend_limit == nil
  end

  test "live Claude restart fixture parses the post-restart observation" do
    fixture = load_fixture("claude/status-line-restart-live.json")

    result =
      parse_fixture("claude/status-line-restart-live.json", :claude, ~U[2026-08-29 07:35:46Z])

    assert result.state == "observed"
    assert result.availability == "available"
    assert result.windows.five_hour.used_percent == 26
    assert result.windows.seven_day.used_percent == 94

    assert Enum.map(fixture["observations"], & &1["rate_limit_signal"]) == [
             "absent",
             "observed",
             "absent",
             "observed"
           ]

    assert Enum.map(
             fixture["observations"],
             &get_in(&1, ["rate_limits", "five_hour", "used_percentage"])
           ) == [nil, 25, nil, 26]

    assert fixture["comparison"] == "divergent"
  end

  test "live Claude concurrent fixture parses identical post-response snapshots" do
    fixture = load_fixture("claude/status-line-concurrent-live.json")

    result =
      parse_fixture("claude/status-line-concurrent-live.json", :claude, ~U[2026-08-29 07:36:16Z])

    assert result.state == "observed"
    assert result.availability == "available"
    assert result.windows.five_hour.used_percent == 26
    assert result.windows.seven_day.used_percent == 94
    assert fixture["comparison"] == "identical"

    post_response =
      fixture["observations"]
      |> Enum.filter(&(&1["rate_limit_signal"] == "observed"))
      |> Enum.map(&get_in(&1, ["rate_limits", "five_hour", "used_percentage"]))

    assert post_response == [26, 26]
  end

  test "live Claude refresh fixture records repeated callback timing" do
    fixture = load_fixture("claude/status-line-refresh-live.json")

    result =
      parse_fixture("claude/status-line-refresh-live.json", :claude, ~U[2026-08-29 07:37:40Z])

    assert result.state == "observed"
    assert result.windows.five_hour.used_percent == 26
    assert result.windows.seven_day.used_percent == 94
    assert fixture["refresh_interval_seconds"] == 1
    assert fixture["comparison"] == "callbacks_received"
    assert length(fixture["observations"]) == 5

    assert fixture["observations"]
           |> Enum.map(& &1["observed_at"])
           |> Enum.uniq()
           |> length() == 5
  end

  test "live Claude tool-mode fixture does not overclaim tool execution" do
    fixture = load_fixture("claude/status-line-tools-live.json")

    result =
      parse_fixture("claude/status-line-tools-live.json", :claude, ~U[2026-08-29 07:37:51Z])

    assert result.state == "observed"
    assert result.windows.five_hour.used_percent == 27
    assert result.windows.seven_day.used_percent == 94
    assert fixture["tool_execution"] == "not_asserted_by_sanitized_capture"
  end

  test "valid Claude windows without captured_at remain unknown" do
    fixture = %{
      "payload" => %{
        "rate_limits" => %{
          "five_hour" => %{"used_percentage" => 23.5, "resets_at" => 1_738_425_600},
          "seven_day" => %{"used_percentage" => 41.2, "resets_at" => 1_738_857_600}
        }
      }
    }

    result = CapacityParser.parse(:claude, fixture, now: @evaluation_time)

    assert result.state == "unknown"
    assert result.availability == "unknown"
    assert result.confidence == "none"
    assert result.freshness.state == "unknown"
    assert result.reason == "missing_or_invalid_observation_timestamp"
  end

  test "Claude refusal with an unknown timestamp has no confidence" do
    fixture = %{
      "payload" => %{
        "type" => "result",
        "subtype" => "rate_limit",
        "is_error" => true
      }
    }

    result = CapacityParser.parse(:claude, fixture, now: @evaluation_time)

    assert result.state == "refused"
    assert result.availability == "refused"
    assert result.confidence == "none"
    assert result.freshness.state == "unknown"
  end

  test "future Claude observations fail closed as freshness unknown" do
    fixture = %{
      "captured_at" => "2026-08-29T04:31:00.001Z",
      "payload" => %{
        "rate_limits" => %{
          "five_hour" => %{"used_percentage" => 23.5, "resets_at" => 1_738_425_600},
          "seven_day" => %{"used_percentage" => 41.2, "resets_at" => 1_738_857_600}
        }
      }
    }

    result = CapacityParser.parse(:claude, fixture, now: @evaluation_time)

    assert result.state == "unknown"
    assert result.availability == "unknown"
    assert result.confidence == "none"
    assert result.freshness == %{state: "unknown", age_seconds: nil, max_age_seconds: 300}
    assert result.reason == "missing_or_invalid_observation_timestamp"
  end

  test "Claude missing status-line limits is unknown" do
    result = parse_fixture("claude/missing-before-response.json", :claude)

    assert result.state == "unknown"
    assert result.availability == "unknown"
    assert result.reason == "rate_limits_absent_before_first_response_or_unsupported_subscription"
    assert result.observed_at == "2026-08-29T04:30:00.000Z"
  end

  test "malformed Claude values become unknown" do
    result = parse_fixture("claude/malformed-replay.json", :claude)

    assert result.state == "unknown"
    assert result.confidence == "none"
    assert result.reason == "malformed_claude_window"
  end

  test "a known Claude refusal shape is explicit without inventing windows" do
    result = parse_fixture("claude/refusal-unverified.json", :claude)

    assert result.state == "refused"
    assert result.availability == "refused"
    assert result.confidence == "none"
    assert result.windows == %{}
    assert result.reason == "cli_reported_rate_limit_refusal_without_capacity_snapshot"
  end

  test "generic Claude provider errors are not classified as absent limits" do
    fixture = %{
      "captured_at" => "2026-08-29T04:30:00.000Z",
      "payload" => %{
        "type" => "result",
        "subtype" => "provider_error",
        "is_error" => true
      }
    }

    result = CapacityParser.parse(:claude, fixture, now: @evaluation_time)

    assert result.state == "unknown"
    assert result.availability == "unknown"
    assert result.source_event == "headless_result_error"
    assert result.details.subtype == "provider_error"
    assert result.reason == "provider_error"
  end

  test "disconnect and invalid JSON remain unknown" do
    disconnect = parse_fixture("codex/disconnect-unverified.json", :codex)
    malformed_json = CapacityParser.parse_json(:codex, "not-json", now: @evaluation_time)

    assert disconnect.state == "unknown"
    assert disconnect.reason == "missing_rate_limits"
    assert malformed_json.state == "unknown"
    assert malformed_json.reason == "malformed_json"
    assert malformed_json.windows == %{}
  end

  test "concurrent Codex observations are identical in the captured sample" do
    fixture = load_fixture("codex/concurrent-read-live.json")
    observations = fixture["observations"]
    result = CapacityParser.parse(:codex, fixture, now: ~U[2026-08-29 05:35:05Z])

    assert observations |> Enum.map(& &1["rate_limits"]) |> Enum.uniq() |> length() == 1
    assert result.state == "observed"
    assert result.availability == "available"
    assert fixture["captured_at"] == "2026-08-29T05:35:03.082Z"
    assert result.windows.primary.used_percent == 26
    assert result.windows.secondary.used_percent == 18

    assert Enum.map(observations, & &1["observed_at"]) == [
             "2026-08-29T05:35:03.069Z",
             "2026-08-29T05:35:03.029Z"
           ]
  end

  test "Codex process-restart fixture parses the re-read snapshot" do
    fixture = load_fixture("codex/restart-read-live.json")
    result = parse_fixture("codex/restart-read-live.json", :codex, ~U[2026-08-29 05:22:18Z])

    assert result.state == "observed"
    assert result.availability == "available"
    assert result.confidence == "high"
    assert result.windows.primary.used_percent == 22
    assert result.windows.secondary.used_percent == 18

    assert Enum.map(
             fixture["observations"],
             &get_in(&1, ["rate_limits", "primary", "used_percent"])
           ) == [22, 22]

    assert Enum.map(
             fixture["observations"],
             &get_in(&1, ["rate_limits", "secondary", "used_percent"])
           ) == [18, 18]
  end

  test "every Gate 0A fixture yields an explicit normalized state" do
    fixture_paths =
      ["codex", "claude"]
      |> Enum.flat_map(&Path.wildcard(Path.join(@fixture_root, &1 <> "/*.json")))

    for path <- fixture_paths do
      provider = if String.contains?(path, "/claude/"), do: :claude, else: :codex
      fixture = path |> File.read!() |> Jason.decode!()
      result = CapacityParser.parse(provider, fixture, now: @latest_codex_evaluation_time)

      assert result.state in ["observed", "degraded", "refused", "unknown"]
      assert result.availability in ["available", "refused", "unknown"]
      assert result.confidence in ["high", "medium", "low", "none"]
      assert is_map(result.windows)
      assert Map.has_key?(result, :freshness)

      if result.freshness.state == "unknown" do
        refute result.state == "observed"
        refute result.availability == "available"
        refute result.confidence == "high"
      end

      if is_binary(fixture["captured_at"]) do
        case DateTime.from_iso8601(fixture["captured_at"]) do
          {:ok, captured_at, _offset} ->
            if DateTime.compare(captured_at, @latest_codex_evaluation_time) == :gt do
              assert result.freshness.state == "unknown"
              assert result.state == "unknown"
              assert result.availability == "unknown"
              assert result.confidence == "none"
            end

          {:error, _reason} ->
            :ok
        end
      end
    end
  end

  test "provider executable rejects unsupported modes without raw payload" do
    probe = Path.expand("../tools/gate_0a/provider_probe.js", __DIR__)
    {output, exit_status} = System.cmd("node", [probe, "unsupported"], stderr_to_stdout: true)
    result = Jason.decode!(output)

    assert exit_status == 2
    assert result["outcome"] == "unsupported_probe_argument"
    assert result["supported_arguments"] == ["codex", "claude"]
    refute Map.has_key?(result, "token")
  end

  test "provider executable reports a missing Codex binary through rpcFailure safely" do
    node = System.find_executable("node")
    probe = Path.expand("../tools/gate_0a/provider_probe.js", __DIR__)

    {output, exit_status} =
      System.cmd(node, [probe, "codex"],
        env: [{"PATH", "/usr/bin"}],
        stderr_to_stdout: true
      )

    result = Jason.decode!(output)

    assert exit_status == 1
    assert result["outcome"] == "failed"
    assert result["failure"] == %{"category" => "executable_unavailable"}
    refute String.contains?(output, "Error:")
    refute Map.has_key?(result, "token")
  end

  defp parse_fixture(name, provider, now \\ @evaluation_time) do
    fixture = load_fixture(name)
    CapacityParser.parse(provider, fixture, now: now)
  end

  defp load_fixture(name) do
    @fixture_root
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end
end
