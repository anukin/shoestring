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

  test "a known Claude refusal shape drives reactive fallback without inventing windows" do
    result = parse_fixture("claude/refusal-unverified.json", :claude)

    assert result.state == "refused"
    assert result.availability == "refused"
    assert result.confidence == "medium"
    assert result.windows == %{}
    assert result.reason == "cli_reported_rate_limit_refusal_without_capacity_snapshot"
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

    assert observations |> Enum.map(& &1["rate_limits"]) |> Enum.uniq() |> length() == 1
    assert fixture["comparison"] == "identical"
  end

  test "Claude executable reports the authentication blocker without raw payload" do
    probe = Path.expand("../tools/gate_0a/provider_probe.js", __DIR__)
    {output, exit_status} = System.cmd("node", [probe, "claude"], stderr_to_stdout: true)
    result = Jason.decode!(output)

    assert exit_status == 0
    assert result["provider"] == "claude"
    assert result["authentication"] == %{"logged_in" => false, "auth_method" => "none"}
    assert result["live_capacity_probe"] == "blocked_not_authenticated"
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
