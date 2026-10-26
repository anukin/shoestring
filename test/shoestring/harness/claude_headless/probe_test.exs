defmodule Shoestring.Harness.ClaudeHeadless.ProbeTest do
  @moduledoc """
  `ClaudeHeadless.probe/1`, which a Claude Elf's lease renewal observes
  through: Claude's own latest usage reading, or an honest unknown. No
  provider CLI runs.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.Harness.{Capacity, CapacitySnapshot, ClaudeHeadless, Observatory}

  # A reading as a headless Claude run records it: its `rate_limit_event`
  # (the 2.1.310 shape) through the same normalization `Session` uses.
  defp reading!(now, utilization) do
    resets = now |> DateTime.add(3_600) |> DateTime.to_unix()

    frame = %{
      "type" => "rate_limit_event",
      "rate_limit_info" => %{
        "status" => "allowed",
        "rateLimitType" => "five_hour",
        "unifiedWindows" => %{
          "five_hour" => %{
            "utilization" => utilization,
            "resetsAt" => resets,
            "status" => "allowed"
          },
          "seven_day" => %{
            "utilization" => 0.1,
            "resetsAt" => resets + 86_400,
            "status" => "allowed"
          }
        }
      }
    }

    {:ok, snapshot} =
      Capacity.normalize(:claude, :headless_stream_json, frame,
        version: "2.1.310",
        now: now,
        captured_at: now,
        adapter_id: "claude_headless_stream_json",
        scope: "subscription"
      )

    {:ok, _, _} = Observatory.ingest(snapshot, now: now)
    snapshot
  end

  # The ledger keeps microseconds; compare what the windows say.
  defp windows(snapshot),
    do:
      Enum.map(
        snapshot.windows,
        &{&1.kind, &1.state, &1.used_percent, DateTime.to_unix(&1.reset_at)}
      )

  test "without a Claude reading the probe is an honest unknown, a new one each time" do
    assert {:ok, %CapacitySnapshot{} = first} = ClaudeHeadless.probe(%{})
    assert first.capacity_state == :unknown
    assert first.confidence == :none
    assert first.windows == []
    assert first.source.provider_id == "claude"

    assert {:ok, second} = ClaudeHeadless.probe(%{})
    assert second.snapshot_id != first.snapshot_id
  end

  test "the probe answers with Claude's latest reading under a new id each time" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    _older = reading!(DateTime.add(now, -60), 0.4)
    latest = reading!(now, 0.55)

    assert {:ok, first} = ClaudeHeadless.probe(%{})
    assert {:ok, second} = ClaudeHeadless.probe(%{})

    for probed <- [first, second] do
      # The reading's own numbers and age: nothing is refreshed or invented.
      assert probed.capacity_state == latest.capacity_state
      assert windows(probed) == windows(latest)
      assert DateTime.compare(probed.observed_at, latest.observed_at) == :eq
      assert DateTime.compare(probed.expires_at, latest.expires_at) == :eq
      assert probed.extensions["claude-headless:observed_snapshot_id"] == latest.snapshot_id
    end

    # Each probe is its own observation, so each renewal judges it afresh.
    assert first.snapshot_id != latest.snapshot_id
    assert second.snapshot_id != first.snapshot_id
  end
end
