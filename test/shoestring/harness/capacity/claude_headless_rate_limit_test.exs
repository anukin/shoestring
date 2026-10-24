defmodule Shoestring.Harness.Capacity.ClaudeHeadlessRateLimitTest do
  use ExUnit.Case, async: true

  alias Shoestring.Harness.{Capacity, CapacitySnapshot}
  alias Shoestring.Harness.Capacity.Fixtures

  @now ~U[2026-10-24 02:00:51Z]

  setup do
    %{fixture: Fixtures.load_fixture!("claude/headless-rate-limit-event-2.1.310-live.json")}
  end

  defp normalize(frame, opts \\ []) do
    Capacity.normalize(
      :claude,
      :headless_stream_json,
      frame,
      Keyword.merge([version: "2.1.310", now: @now, captured_at: @now], opts)
    )
  end

  defp frame(windows, info \\ %{}) do
    %{
      "type" => "rate_limit_event",
      "rate_limit_info" => Map.merge(%{"status" => "allowed", "unifiedWindows" => windows}, info)
    }
  end

  defp window(snapshot, kind), do: Enum.find(snapshot.windows, &(&1.kind == kind))

  test "the captured 2.1.310 frame becomes a conservative Claude observation", c do
    assert {:ok, snapshot} = normalize(c.fixture["payload"])

    assert snapshot.source.provider_id == "claude"
    assert snapshot.source.invocation_mode == "headless_stream_json"
    assert snapshot.source.event == :update_notification
    assert snapshot.support_tier == :conservative_partial
    assert snapshot.compatibility_state == :compatible
    assert snapshot.capacity_state == :degraded
    assert snapshot.confidence == :medium
    assert snapshot.observed_at == @now
    assert snapshot.scope == "subscription"

    assert %{state: :observed, used_percent: 15.0, reset_at: ~U[2026-10-24 05:50:00Z]} =
             window(snapshot, "five_hour")

    assert %{state: :observed, used_percent: 15.0, reset_at: ~U[2026-10-24 20:00:00Z]} =
             window(snapshot, "seven_day")

    assert snapshot.extensions == %{
             "claude:rate_limit_status" => "allowed",
             "claude:rate_limit_type" => "five_hour",
             "claude:five_hour_status" => "allowed",
             "claude:seven_day_status" => "allowed",
             "capacity:cli_version" => "2.1.310"
           }

    refute CapacitySnapshot.eligible?(snapshot, @now)
  end

  test "an older frame without per-window status still parses" do
    older =
      frame(%{
        "five_hour" => %{"utilization" => 0.62, "resetsAt" => 1_788_696_600},
        "seven_day" => %{"utilization" => 0.22, "resetsAt" => 1_789_243_200}
      })

    assert {:ok, snapshot} = normalize(older, version: "2.1.263")
    assert snapshot.compatibility_state == :compatible
    assert window(snapshot, "five_hour").used_percent == 62.0
    assert window(snapshot, "seven_day").used_percent == 22.0
    refute Map.has_key?(snapshot.extensions, "claude:five_hour_status")
  end

  test "a warning status is recorded and the fraction becomes whole percent" do
    warning =
      frame(
        %{
          "five_hour" => %{
            "utilization" => 0.83,
            "resetsAt" => 1_792_821_000,
            "status" => "allowed_warning"
          },
          "seven_day" => %{"utilization" => 0.4, "resetsAt" => 1_792_872_000}
        },
        %{"status" => "allowed_warning"}
      )

    assert {:ok, snapshot} = normalize(warning)
    assert window(snapshot, "five_hour").used_percent == 83.0
    assert snapshot.extensions["claude:rate_limit_status"] == "allowed_warning"
    assert snapshot.extensions["claude:five_hour_status"] == "allowed_warning"
    assert snapshot.capacity_state == :degraded
  end

  test "a missing window is unknown, never zero" do
    partial = frame(%{"five_hour" => %{"utilization" => 0.3, "resetsAt" => 1_792_821_000}})

    assert {:ok, snapshot} = normalize(partial)
    assert window(snapshot, "five_hour").used_percent == 30.0

    assert window(snapshot, "seven_day") == %{
             kind: "seven_day",
             state: :unknown,
             reason: "absent_in_rate_limit_event"
           }

    assert snapshot.reason =~ "partial_window_observation"
  end

  test "malformed or absent windows produce no observed window" do
    for bad <- [
          frame(%{"five_hour" => %{"utilization" => "high", "resetsAt" => 1_792_821_000}}),
          frame(%{"five_hour" => %{"utilization" => 1.5, "resetsAt" => 1_792_821_000}}),
          %{"type" => "rate_limit_event", "rate_limit_info" => %{"status" => "allowed"}},
          %{"type" => "rate_limit_event", "rate_limit_info" => "allowed"},
          frame(%{})
        ] do
      assert {:ok, snapshot} = normalize(bad)
      assert snapshot.capacity_state == :unknown
      assert snapshot.source.event == :update_notification
      refute Enum.any?(snapshot.windows, &(&1.state == :observed))
    end
  end

  test "an untested CLI version is degraded" do
    assert {:ok, snapshot} =
             normalize(
               frame(%{"five_hour" => %{"utilization" => 0.1, "resetsAt" => 1_792_821_000}}),
               version: "2.1.311"
             )

    assert snapshot.compatibility_state == :degraded
    assert snapshot.reason =~ "untested_cli_version: 2.1.311"
  end

  test "only plain provider labels are kept as status evidence" do
    odd =
      frame(
        %{
          "five_hour" => %{
            "utilization" => 0.1,
            "resetsAt" => 1_792_821_000,
            "status" => "Allowed Warning!"
          }
        },
        %{"status" => String.duplicate("a", 41), "rateLimitType" => "five_hour"}
      )

    assert {:ok, snapshot} = normalize(odd)

    assert snapshot.extensions == %{
             "claude:rate_limit_type" => "five_hour",
             "capacity:cli_version" => "2.1.310"
           }
  end
end
