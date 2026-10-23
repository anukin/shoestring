defmodule Shoestring.Harness.Capacity.ClaudeInstalledVersionTest do
  use ExUnit.Case, async: true

  alias Shoestring.Cobbler.AdmissionEvaluation
  alias Shoestring.Harness.{Capacity, CapacitySnapshot, Security}
  alias Shoestring.Harness.Capacity.Fixtures

  setup do
    fixture = Fixtures.load_fixture!("claude/status-line-single-2.1.309-live.json")
    {:ok, now, _} = DateTime.from_iso8601(fixture["captured_at"])
    %{fixture: fixture, now: now}
  end

  test "the captured Claude 2.1.309 callback is compatible but stays conservative", c do
    assert {:ok, snapshot} = normalize(c.fixture, "2.1.309", c.now)
    assert snapshot.compatibility_state == :compatible
    assert snapshot.support_tier == :conservative_partial
    assert snapshot.capacity_state == :degraded
    assert snapshot.reason == "conservative_partial_observation"
    assert Enum.map(snapshot.windows, & &1.used_percent) == [4, 6]

    assert Enum.map(snapshot.windows, & &1.reset_at) ==
             Enum.map([1_792_792_800, 1_792_872_000], &DateTime.from_unix!/1)

    refute CapacitySnapshot.eligible?(snapshot, c.now)

    assert {:ok, decision} =
             AdmissionEvaluation.evaluate(%{}, candidate(snapshot), snapshot, nil, now: c.now)

    assert decision.result == :require_confirmation
  end

  test "adopting 2.1.309 does not adopt neighbouring versions", c do
    for version <- ["2.1.308", "2.1.310"] do
      assert {:ok, snapshot} = normalize(c.fixture, version, c.now)
      assert snapshot.compatibility_state == :degraded
      assert snapshot.reason =~ "untested_cli_version: #{version}"
      refute CapacitySnapshot.eligible?(snapshot, c.now)
    end
  end

  test "the captured callback retains capacity fields and excludes private ones", c do
    assert Security.scan_term(c.fixture) == []
    assert c.fixture["payload"]["version"] == "2.1.309"
    assert c.fixture["payload"]["rate_limits"]["five_hour"]["used_percentage"] == 4

    refute Enum.any?(
             ~w(session_id transcript_path cwd workspace model email prompt),
             &String.contains?(Jason.encode!(c.fixture), &1)
           )
  end

  defp normalize(fixture, version, now),
    do: Capacity.normalize(:claude, :interactive_status_line, fixture, version: version, now: now)

  defp candidate(snapshot) do
    %{
      provider_id: "claude",
      adapter_id: snapshot.source.adapter_id,
      scope: snapshot.scope,
      support_tier: snapshot.support_tier,
      compatibility_state: snapshot.compatibility_state,
      capabilities: ["supervised_execution"]
    }
  end
end
