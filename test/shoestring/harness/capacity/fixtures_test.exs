defmodule Shoestring.Harness.Capacity.FixturesTest do
  use ExUnit.Case, async: false

  alias Shoestring.Harness.Capacity
  alias Shoestring.Harness.Capacity.Fixtures, as: CapacityFixtures

  @codex_eval_time ~U[2026-08-29 04:38:25Z]
  @claude_eval_time ~U[2026-08-29 07:34:25Z]

  describe "secret scanning over all tracked fixtures" do
    test "every tracked test fixture is 100% free of secrets, tokens, and user paths" do
      assert {:ok, count} = CapacityFixtures.scan_all_fixtures()
      assert count == 21
    end

    test "scanner successfully flags forbidden patterns with safe diagnostics" do
      bad_secret = %{"safe_key" => "sk-1234567890abcdef", "sub" => "safe"}
      violations = CapacityFixtures.scan_term(bad_secret)
      assert violations != []
      assert Enum.any?(violations, &(&1 =~ "sk_token"))
      # Diagnostic must never leak the secret substring itself
      refute Enum.any?(violations, &(&1 =~ "sk-1234567890abcdef"))

      bad_path = %{"directory" => "/Users/developer/code"}
      path_violations = CapacityFixtures.scan_term(bad_path)
      assert path_violations != []
      assert Enum.any?(path_violations, &(&1 =~ "user_filesystem_path"))
      # Diagnostic must never leak the path substring itself
      refute Enum.any?(path_violations, &(&1 =~ "/Users/developer/code"))

      bad_key = %{"raw_transcript" => "some text"}
      key_violations = CapacityFixtures.scan_term(bad_key)
      assert key_violations != []
      assert Enum.any?(key_violations, &(&1 =~ "forbidden key"))
    end

    test "scan_all_fixtures/1 fails when zero fixtures are found without mutating global env" do
      tmp_empty_dir =
        Path.join(System.tmp_dir!(), "empty_capacity_fixtures_#{Ecto.UUID.generate()}")

      File.mkdir_p!(tmp_empty_dir)

      try do
        assert {:error, :no_fixtures_found} = CapacityFixtures.scan_all_fixtures(tmp_empty_dir)
      after
        File.rm_rf!(tmp_empty_dir)
      end
    end

    test "does not produce false positives on benign keys like prompt_tokens, transcription, or secretary" do
      benign_fixture = %{
        "usage" => %{"prompt_tokens" => 42, "total_tokens" => 100},
        "transcription" => "audio transcription text",
        "secretary" => "administrative assistant notes",
        "session" => "valid_session_tag"
      }

      assert CapacityFixtures.scan_term(benign_fixture) == []
    end

    test "poisoned JSON fixtures with harmless non-sk values are rejected by scanner and safe_observation?/1" do
      poisoned_payloads = [
        {"token", ~s({"captured_at": "2026-08-29T04:38:16Z", "token": "harmless_token_val"})},
        {"api_key", ~s({"captured_at": "2026-08-29T04:38:16Z", "api_key": "harmless_key_val"})},
        {"apiKey", ~s({"captured_at": "2026-08-29T04:38:16Z", "apiKey": "harmless_key_val"})},
        {"access_token",
         ~s({"captured_at": "2026-08-29T04:38:16Z", "access_token": "harmless_access"})},
        {"refresh_token",
         ~s({"captured_at": "2026-08-29T04:38:16Z", "refresh_token": "harmless_refresh"})},
        {"password", ~s({"captured_at": "2026-08-29T04:38:16Z", "password": "harmless_pass"})},
        {"secret", ~s({"captured_at": "2026-08-29T04:38:16Z", "secret": "harmless_secret"})},
        {"cookie", ~s({"captured_at": "2026-08-29T04:38:16Z", "cookie": "harmless_cookie"})},
        {"authorization",
         ~s({"captured_at": "2026-08-29T04:38:16Z", "authorization": "harmless_auth"})},
        {"account_id",
         ~s({"captured_at": "2026-08-29T04:38:16Z", "account_id": "harmless_acct"})},
        {"session_id",
         ~s({"captured_at": "2026-08-29T04:38:16Z", "session_id": "harmless_sess"})},
        {"sessionId", ~s({"captured_at": "2026-08-29T04:38:16Z", "sessionId": "harmless_sess"})},
        {"thread_id",
         ~s({"captured_at": "2026-08-29T04:38:16Z", "thread_id": "harmless_thread"})},
        {"threadId", ~s({"captured_at": "2026-08-29T04:38:16Z", "threadId": "harmless_thread"})},
        {"turn_id", ~s({"captured_at": "2026-08-29T04:38:16Z", "turn_id": "harmless_turn"})},
        {"turnId", ~s({"captured_at": "2026-08-29T04:38:16Z", "turnId": "harmless_turn"})},
        {"prompt", ~s({"captured_at": "2026-08-29T04:38:16Z", "prompt": "harmless prompt"})},
        {"transcript",
         ~s({"captured_at": "2026-08-29T04:38:16Z", "transcript": "harmless transcript"})},
        {"raw_transcript",
         ~s({"captured_at": "2026-08-29T04:38:16Z", "raw_transcript": "harmless raw transcript"})},
        {"mac_path",
         ~s({"captured_at": "2026-08-29T04:38:16Z", "path": "/Users/developer/project"})},
        {"linux_path",
         ~s({"captured_at": "2026-08-29T04:38:16Z", "path": "/home/developer/project"})}
      ]

      for {name, json_str} <- poisoned_payloads do
        raw_violations = Shoestring.Harness.Security.scan_json(json_str)
        assert raw_violations != [], "Expected scanner to reject raw JSON for: #{name}"

        decoded = Jason.decode!(json_str)
        term_violations = CapacityFixtures.scan_term(decoded)
        assert term_violations != [], "Expected scan_term to reject term for: #{name}"

        refute Capacity.safe_observation?(decoded),
               "Expected safe_observation?/1 to reject: #{name}"

        assert {:error, :contains_secrets_or_forbidden_content} =
                 Capacity.normalize(:codex, :app_server_stdio, decoded)
      end
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
