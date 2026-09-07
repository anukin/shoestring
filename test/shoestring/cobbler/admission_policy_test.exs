defmodule Shoestring.Cobbler.AdmissionPolicyTest do
  use ExUnit.Case, async: true

  alias Shoestring.Cobbler.AdmissionPolicy

  describe "default/0" do
    test "provides operational default thresholds and conservative lease bounds" do
      policy = AdmissionPolicy.default()

      assert policy.version == 1
      assert policy.five_hour_reserve_percent == 20
      assert policy.weekly_reserve_percent == 10
      assert policy.five_hour_max_used_percent == 80
      assert policy.weekly_max_used_percent == 90
      assert policy.stale_after_seconds == 300
      assert policy.delayed_recheck_seconds == 60
      assert policy.response_budget == 10
      assert policy.tool_budget == 25
      assert policy.deadline_seconds == 300
      assert policy.checkpoint_cadence == 1
      assert policy.reserves == %{response: 1, tool: 1}
      assert "supervised_execution" in policy.supported_capabilities
      assert policy.candidate_priority == ["codex", "claude"]
    end
  end

  describe "new/1" do
    test "accepts valid overrides and returns an AdmissionPolicy struct" do
      attrs = %{
        five_hour_reserve_percent: 25,
        weekly_reserve_percent: 15,
        five_hour_max_used_percent: 75,
        weekly_max_used_percent: 85,
        stale_after_seconds: 600,
        delayed_recheck_seconds: 120,
        response_budget: 20,
        tool_budget: 50,
        deadline_seconds: 600,
        checkpoint_cadence: 2,
        reserves: %{response: 2, tool: 2}
      }

      assert {:ok, policy} = AdmissionPolicy.new(attrs)
      assert policy.five_hour_reserve_percent == 25
      assert policy.weekly_reserve_percent == 15
      assert policy.five_hour_max_used_percent == 75
      assert policy.weekly_max_used_percent == 85
      assert policy.stale_after_seconds == 600
      assert policy.delayed_recheck_seconds == 120
      assert policy.response_budget == 20
      assert policy.tool_budget == 50
      assert policy.deadline_seconds == 600
      assert policy.checkpoint_cadence == 2
      assert policy.reserves == %{response: 2, tool: 2}
    end

    test "rejects invalid version" do
      assert {:error, changeset} = AdmissionPolicy.new(%{version: 2})
      assert "must equal 1" in errors_on(changeset).version
    end

    test "rejects negative or out-of-range percentages" do
      assert {:error, changeset} = AdmissionPolicy.new(%{five_hour_reserve_percent: -5})

      assert "must be a percentage between 0 and 100" in errors_on(changeset).five_hour_reserve_percent

      assert {:error, changeset} = AdmissionPolicy.new(%{weekly_max_used_percent: 105})

      assert "must be a percentage between 0 and 100" in errors_on(changeset).weekly_max_used_percent
    end

    test "rejects non-positive integers for bounds" do
      assert {:error, changeset} = AdmissionPolicy.new(%{response_budget: 0})
      assert "must be a positive integer" in errors_on(changeset).response_budget

      assert {:error, changeset} = AdmissionPolicy.new(%{deadline_seconds: -10})
      assert "must be a positive integer" in errors_on(changeset).deadline_seconds
    end

    test "rejects invalid reserves structure" do
      assert {:error, changeset} = AdmissionPolicy.new(%{reserves: "not_a_map"})
      assert "must be an object" in errors_on(changeset).reserves

      assert {:error, changeset} = AdmissionPolicy.new(%{reserves: %{response: -1, tool: 1}})
      assert "response and tool must be non-negative integers" in errors_on(changeset).reserves
    end
  end

  describe "to_map/1" do
    test "serializes policy to string-keyed map" do
      policy = AdmissionPolicy.default()
      map = AdmissionPolicy.to_map(policy)

      assert is_map(map)
      assert map["version"] == 1
      assert map["five_hour_reserve_percent"] == 20
      assert map["weekly_reserve_percent"] == 10
      assert map["five_hour_max_used_percent"] == 80
      assert map["weekly_max_used_percent"] == 90
      assert map["reserves"] == %{"response" => 1, "tool" => 1}

      # Roundtrip check
      assert {:ok, roundtripped} = AdmissionPolicy.new(map)
      assert roundtripped == policy
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
