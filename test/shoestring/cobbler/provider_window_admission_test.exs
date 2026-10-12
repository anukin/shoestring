defmodule Shoestring.Cobbler.ProviderWindowAdmissionTest do
  use ExUnit.Case, async: true

  alias Shoestring.Cobbler.AdmissionEvaluation
  alias Shoestring.Harness.{Capacity, EventPayload}

  @now ~U[2026-10-11 12:00:00Z]
  @candidate %{
    provider_id: "codex",
    adapter_id: "codex_app_server_stdio",
    scope: "subscription",
    support_tier: :proactive,
    compatibility_state: :compatible,
    capabilities: ["supervised_execution"]
  }

  test "real normalized Codex windows admit healthy usage without losing provider facts" do
    snapshot = codex(15, 9)
    assert Enum.map(snapshot.windows, & &1.kind) == ["primary", "secondary"]

    for observation <- [snapshot, EventPayload.capacity_snapshot(snapshot, nil)] do
      assert {:ok, %{result: :admit}} = evaluate(observation)
    end

    assert snapshot.extensions["codex:primary_window_minutes"] == 300
    assert snapshot.extensions["codex:secondary_window_minutes"] == 10_080
  end

  test "both duration-bound Codex reserve thresholds refuse admission" do
    for {primary, secondary, reason} <- [
          {80, 9, "reserve_breach_five_hour"},
          {15, 90, "reserve_breach_weekly"}
        ] do
      snapshot = codex(primary, secondary)

      for observation <- [snapshot, EventPayload.capacity_snapshot(snapshot, nil)] do
        assert {:ok, decision} = evaluate(observation)
        assert decision.result == :defer_until
        assert decision.reason_code == reason
      end
    end
  end

  test "missing or changed duration is not inferred from provider window position" do
    for duration <- [nil, 60, "300", -1] do
      assert {:ok, %{result: :require_confirmation, reason_code: "missing_window_five_hour"}} =
               codex(15, 9, duration) |> evaluate()
    end
  end

  test "missing weekly duration stays unknown and swapped durations retain the correct reserve" do
    assert {:ok, %{result: :require_confirmation, reason_code: "missing_window_weekly"}} =
             codex(15, 9, 300, nil) |> evaluate()

    assert {:ok, %{result: :admit}} = codex(9, 15, 10_080, 300) |> evaluate()

    assert {:ok, %{result: :defer_until, reason_code: "reserve_breach_weekly"}} =
             codex(90, 15, 10_080, 300) |> evaluate()
  end

  test "Claude seven-day window also obeys the weekly reserve" do
    payload = %{
      "rate_limits" => %{
        "five_hour" => %{"used_percentage" => 15, "resets_at" => "2026-10-11T17:00:00Z"},
        "seven_day" => %{"used_percentage" => 90, "resets_at" => "2026-10-18T12:00:00Z"}
      }
    }

    {:ok, snapshot} =
      Capacity.normalize(:claude, :interactive_status_line, payload,
        version: "2.1.251",
        now: @now,
        captured_at: @now,
        scope: "subscription"
      )

    candidate = %{
      @candidate
      | provider_id: "claude",
        adapter_id: "claude_status_line",
        support_tier: :conservative_partial
    }

    for observation <- [snapshot, EventPayload.capacity_snapshot(snapshot, nil)] do
      assert {:ok, %{result: :defer_until, reason_code: "reserve_breach_weekly"}} =
               AdmissionEvaluation.evaluate(
                 %{requested_capability: "supervised_execution", scope: "subscription"},
                 candidate,
                 observation,
                 nil,
                 now: @now
               )
    end
  end

  defp evaluate(snapshot),
    do:
      AdmissionEvaluation.evaluate(
        %{requested_capability: "supervised_execution", scope: "subscription"},
        @candidate,
        snapshot,
        nil,
        now: @now
      )

  defp codex(primary, secondary, duration \\ 300, secondary_duration \\ 10_080) do
    payload = %{
      "result" => %{
        "rateLimits" => %{
          "primary" => %{
            "usedPercent" => primary,
            "windowDurationMins" => duration,
            "resetsAt" => DateTime.to_unix(DateTime.add(@now, 18_000))
          },
          "secondary" => %{
            "usedPercent" => secondary,
            "windowDurationMins" => secondary_duration,
            "resetsAt" => DateTime.to_unix(DateTime.add(@now, 604_800))
          }
        }
      }
    }

    {:ok, snapshot} =
      Capacity.normalize(:codex, :app_server_stdio, payload,
        version: "0.150.1",
        now: @now,
        captured_at: @now,
        scope: "subscription"
      )

    snapshot
  end
end
