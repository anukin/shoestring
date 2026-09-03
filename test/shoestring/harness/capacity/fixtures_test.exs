defmodule Shoestring.Harness.Capacity.FixturesTest do
  use ExUnit.Case, async: true

  alias Shoestring.Harness.Capacity
  alias Shoestring.Harness.Capacity.Fixtures, as: CapacityFixtures

  @codex_eval_time ~U[2026-08-29 04:38:25Z]
  @claude_eval_time ~U[2026-08-29 07:34:25Z]

  describe "secret scanning over all tracked fixtures" do
    test "every tracked test fixture is 100% free of secrets, tokens, and user paths" do
      assert {:ok, count} = CapacityFixtures.scan_all_fixtures()
      assert count == 21
    end

    test "scanner successfully flags forbidden patterns" do
      bad_secret = %{"token" => "sk-1234567890abcdef", "sub" => "safe"}
      violations = CapacityFixtures.scan_term(bad_secret)
      assert violations != []
      assert Enum.any?(violations, &(&1 =~ "forbidden pattern"))

      bad_path = %{"directory" => "/Users/developer/code"}
      path_violations = CapacityFixtures.scan_term(bad_path)
      assert path_violations != []
      assert Enum.any?(path_violations, &(&1 =~ "/Users/"))

      bad_key = %{"raw_transcript" => "some text"}
      key_violations = CapacityFixtures.scan_term(bad_key)
      assert key_violations != []
      assert Enum.any?(key_violations, &(&1 =~ "forbidden key"))
    end
  end

  describe "all Claude tracked fixtures normalize deterministically" do
    test "claude/normal-official-shape.json" do
      fixture = CapacityFixtures.load_fixture!("claude/normal-official-shape.json")

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :claude,
                 :interactive_status_line,
                 fixture,
                 version: "2.1.251",
                 now: ~U[2026-08-29 04:30:10Z]
               )

      assert snapshot.capacity_state == :degraded
      assert snapshot.support_tier == :conservative_partial
      assert [five_hour, seven_day] = snapshot.windows
      assert five_hour.used_percent == 23.5
      assert seven_day.state == :observed
    end

    test "claude/partial-official-shape.json" do
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
      assert [five_hour, seven_day] = snapshot.windows
      assert five_hour.used_percent == 23.5
      assert seven_day.state == :unknown
    end

    test "claude/status-line-single-live.json" do
      fixture = CapacityFixtures.load_fixture!("claude/status-line-single-live.json")

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :claude,
                 :interactive_status_line,
                 fixture,
                 version: "2.1.251",
                 now: @claude_eval_time
               )

      assert snapshot.capacity_state == :degraded
      assert [five_hour, seven_day] = snapshot.windows
      assert five_hour.used_percent == 25
      assert seven_day.used_percent == 94
    end

    test "claude/status-line-refresh-live.json" do
      fixture = CapacityFixtures.load_fixture!("claude/status-line-refresh-live.json")

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :claude,
                 :interactive_status_line,
                 fixture,
                 version: "2.1.251",
                 now: ~U[2026-08-29 07:37:40Z]
               )

      assert snapshot.capacity_state == :degraded
      assert [five_hour, seven_day] = snapshot.windows
      assert five_hour.used_percent == 26
      assert seven_day.used_percent == 94
    end

    test "claude/status-line-restart-live.json" do
      fixture = CapacityFixtures.load_fixture!("claude/status-line-restart-live.json")

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :claude,
                 :interactive_status_line,
                 fixture,
                 version: "2.1.251",
                 now: ~U[2026-08-29 07:35:46Z]
               )

      assert snapshot.capacity_state == :degraded
      assert [five_hour, seven_day] = snapshot.windows
      assert five_hour.used_percent == 26
      assert seven_day.used_percent == 94
    end

    test "claude/status-line-concurrent-live.json" do
      fixture = CapacityFixtures.load_fixture!("claude/status-line-concurrent-live.json")

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :claude,
                 :interactive_status_line,
                 fixture,
                 version: "2.1.251",
                 now: ~U[2026-08-29 07:36:20Z]
               )

      assert snapshot.capacity_state == :degraded
      assert [five_hour, seven_day] = snapshot.windows
      assert five_hour.used_percent == 26
      assert seven_day.used_percent == 94
    end

    test "claude/status-line-tools-live.json" do
      fixture = CapacityFixtures.load_fixture!("claude/status-line-tools-live.json")

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :claude,
                 :interactive_status_line,
                 fixture,
                 version: "2.1.251",
                 now: ~U[2026-08-29 07:37:50Z]
               )

      assert snapshot.capacity_state == :degraded
      assert [five_hour, seven_day] = snapshot.windows
      assert five_hour.used_percent == 27
      assert seven_day.used_percent == 94
    end

    test "claude/missing-before-response.json" do
      fixture = CapacityFixtures.load_fixture!("claude/missing-before-response.json")

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :claude,
                 :interactive_status_line,
                 fixture,
                 version: "2.1.251",
                 now: @claude_eval_time
               )

      assert snapshot.capacity_state == :unknown
      assert snapshot.confidence == :none

      assert snapshot.reason ==
               "rate_limits_absent_before_first_response_or_unsupported_subscription"
    end

    test "claude/stale-replay.json" do
      fixture = CapacityFixtures.load_fixture!("claude/stale-replay.json")

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :claude,
                 :interactive_status_line,
                 fixture,
                 version: "2.1.251",
                 now: ~U[2026-08-29 06:30:00Z]
               )

      assert snapshot.capacity_state == :degraded
      assert snapshot.confidence == :low
      assert snapshot.reason == "stale_observation"
    end

    test "claude/malformed-replay.json" do
      fixture = CapacityFixtures.load_fixture!("claude/malformed-replay.json")

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :claude,
                 :interactive_status_line,
                 fixture,
                 version: "2.1.251",
                 now: @claude_eval_time
               )

      assert snapshot.capacity_state == :unknown
      assert snapshot.confidence == :none
      assert snapshot.reason == "malformed_window_value"
    end

    test "claude/refusal-unverified.json" do
      fixture = CapacityFixtures.load_fixture!("claude/refusal-unverified.json")

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :claude,
                 :interactive_status_line,
                 fixture,
                 version: "2.1.251",
                 now: @claude_eval_time
               )

      assert snapshot.capacity_state == :refused
      assert snapshot.confidence == :low
      assert snapshot.reason == "cli_reported_rate_limit_refusal_without_capacity_snapshot"
    end

    test "claude/auth-preflight-live.json (headless mode is unsupported)" do
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
    end
  end

  describe "all Codex tracked fixtures normalize deterministically" do
    test "codex/normal-read.json" do
      fixture = CapacityFixtures.load_fixture!("codex/normal-read.json")

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :codex,
                 :app_server_stdio,
                 fixture,
                 version: "0.150.1",
                 now: @codex_eval_time
               )

      assert snapshot.capacity_state == :observed
      assert snapshot.confidence == :high
      assert [primary, secondary] = snapshot.windows
      assert primary.used_percent == 13
      assert secondary.used_percent == 16
    end

    test "codex/sparse-update-live.json" do
      fixture = CapacityFixtures.load_fixture!("codex/sparse-update-live.json")

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :codex,
                 :app_server_stdio,
                 fixture,
                 version: "0.150.1",
                 now: @codex_eval_time
               )

      assert snapshot.capacity_state == :observed
      assert snapshot.source.event == :update_notification
      assert [primary, secondary] = snapshot.windows
      assert primary.used_percent == 13
      assert secondary.used_percent == 16
    end

    test "codex/partial-missing-secondary.json" do
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
      assert [primary, secondary] = snapshot.windows
      assert primary.used_percent == 12
      assert secondary.state == :unknown
    end

    test "codex/restart-read-live.json" do
      fixture = CapacityFixtures.load_fixture!("codex/restart-read-live.json")

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :codex,
                 :app_server_stdio,
                 fixture,
                 version: "0.150.1",
                 now: ~U[2026-08-29 05:22:20Z]
               )

      assert snapshot.capacity_state == :observed
      assert [primary, secondary] = snapshot.windows
      assert primary.used_percent == 22
      assert secondary.used_percent == 18
    end

    test "codex/concurrent-read-live.json" do
      fixture = CapacityFixtures.load_fixture!("codex/concurrent-read-live.json")

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :codex,
                 :app_server_stdio,
                 fixture,
                 version: "0.150.1",
                 now: ~U[2026-08-29 05:35:10Z]
               )

      assert snapshot.capacity_state == :observed
      assert [primary, secondary] = snapshot.windows
      assert primary.used_percent == 26
      assert secondary.used_percent == 18
    end

    test "codex/disconnect-unverified.json" do
      fixture = CapacityFixtures.load_fixture!("codex/disconnect-unverified.json")

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :codex,
                 :app_server_stdio,
                 fixture,
                 version: "0.150.1",
                 now: ~U[2026-08-29 04:30:10Z]
               )

      assert snapshot.capacity_state == :unknown
      assert snapshot.confidence == :none
      assert snapshot.reason == "missing_rate_limits"
    end

    test "codex/stale-replay.json" do
      fixture = CapacityFixtures.load_fixture!("codex/stale-replay.json")

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :codex,
                 :app_server_stdio,
                 fixture,
                 version: "0.150.1",
                 now: ~U[2026-08-29 05:30:00Z]
               )

      assert snapshot.capacity_state == :degraded
      assert snapshot.confidence == :low
      assert snapshot.reason == "stale_observation"
    end

    test "codex/malformed-replay.json" do
      fixture = CapacityFixtures.load_fixture!("codex/malformed-replay.json")

      assert {:ok, snapshot} =
               Capacity.normalize(
                 :codex,
                 :app_server_stdio,
                 fixture,
                 version: "0.150.1",
                 now: ~U[2026-08-29 04:30:10Z]
               )

      assert snapshot.capacity_state == :unknown
      assert snapshot.confidence == :none
      assert snapshot.reason == "malformed_window_value"
    end

    test "codex/refusal-unverified.json" do
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
    end
  end
end
