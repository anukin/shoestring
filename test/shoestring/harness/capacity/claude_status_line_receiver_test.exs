defmodule Shoestring.Harness.Capacity.ClaudeStatusLineReceiverTest do
  use ExUnit.Case, async: true

  alias Shoestring.Harness.Capacity.ClaudeStatusLineReceiver
  alias Shoestring.Harness.Capacity.Fixtures, as: CapacityFixtures

  describe "parse/2 with fixtures" do
    test "parses normal official statusLine fixture" do
      fixture = CapacityFixtures.load_fixture!("claude/normal-official-shape.json")

      assert {:ok, parsed} = ClaudeStatusLineReceiver.parse(fixture)
      assert parsed["model"]["display_name"] == "documented-model"
      assert is_map(parsed["rate_limits"])

      five_hour = parsed["rate_limits"]["five_hour"]
      assert five_hour["used_percentage"] == 23.5
      assert five_hour["resets_at"] == 1_738_425_600

      seven_day = parsed["rate_limits"]["seven_day"]
      assert seven_day["used_percentage"] == 41.2
      assert seven_day["resets_at"] == 1_738_857_600
    end

    test "parses partial official statusLine fixture with single window" do
      fixture = CapacityFixtures.load_fixture!("claude/partial-official-shape.json")

      assert {:ok, parsed} = ClaudeStatusLineReceiver.parse(fixture)
      assert parsed["rate_limits"]["five_hour"]["used_percentage"] == 23.5
      assert parsed["rate_limits"]["seven_day"] == nil
    end

    test "parses missing-before-response fixture with nil rate_limits" do
      fixture = CapacityFixtures.load_fixture!("claude/missing-before-response.json")

      assert {:ok, parsed} = ClaudeStatusLineReceiver.parse(fixture)
      assert parsed["rate_limits"] == nil
      assert parsed["model"]["display_name"] == "documented-model"
    end

    test "parses live single statusLine fixture" do
      fixture = CapacityFixtures.load_fixture!("claude/status-line-single-live.json")

      assert {:ok, parsed} = ClaudeStatusLineReceiver.parse(fixture)
      assert parsed["version"] == "2.1.251"
      assert parsed["rate_limits"]["five_hour"]["used_percentage"] == 25
      assert parsed["rate_limits"]["seven_day"]["used_percentage"] == 94
    end

    test "parses refusal fixture as structured refusal envelope" do
      fixture = CapacityFixtures.load_fixture!("claude/refusal-unverified.json")

      assert {:ok, parsed} = ClaudeStatusLineReceiver.parse(fixture)
      assert parsed["type"] == "result"
      assert parsed["subtype"] == "rate_limit"
      assert parsed["is_error"] == true
    end
  end

  describe "parse/2 input formats and bounding" do
    test "decodes valid JSON binary string within size bounds" do
      json =
        ~s({"version":"2.1.251","rate_limits":{"five_hour":{"used_percentage":10,"resets_at":1787994000}}})

      assert {:ok, parsed} = ClaudeStatusLineReceiver.parse(json)
      assert parsed["version"] == "2.1.251"
      assert parsed["rate_limits"]["five_hour"]["used_percentage"] == 10
    end

    test "rejects oversized binary payload (> 64KB)" do
      padding = String.duplicate("x", 70_000)
      large_json = ~s({"padding":"#{padding}"})

      assert {:error, :payload_oversized} = ClaudeStatusLineReceiver.parse(large_json)
    end

    test "rejects map with excessive keys (> 64)" do
      large_map =
        Enum.reduce(1..70, %{}, fn i, acc ->
          Map.put(acc, "key_#{i}", i)
        end)

      assert {:error, :payload_oversized} = ClaudeStatusLineReceiver.parse(large_map)
    end

    test "rejects deeply nested map (> 10 levels)" do
      nested =
        Enum.reduce(1..12, %{"leaf" => true}, fn i, acc ->
          %{"level_#{i}" => acc}
        end)

      assert {:error, :payload_oversized} = ClaudeStatusLineReceiver.parse(nested)
    end

    test "rejects malformed JSON binary" do
      assert {:error, :malformed_json} = ClaudeStatusLineReceiver.parse("{invalid_json:")
    end

    test "rejects non-map scalar or list payloads" do
      assert {:error, :malformed_payload} = ClaudeStatusLineReceiver.parse(12_345)
      assert {:error, :malformed_payload} = ClaudeStatusLineReceiver.parse([1, 2, 3])
      assert {:error, :malformed_json} = ClaudeStatusLineReceiver.parse("bare string")
    end
  end

  describe "parse/2 window validation" do
    test "rejects non-numeric used_percentage" do
      bad = %{
        "rate_limits" => %{
          "five_hour" => %{"used_percentage" => "25", "resets_at" => 1_787_994_000}
        }
      }

      assert {:error, {:malformed_window, "five_hour"}} = ClaudeStatusLineReceiver.parse(bad)
    end

    test "rejects out-of-range used_percentage (< 0 or > 100)" do
      negative = %{
        "rate_limits" => %{
          "five_hour" => %{"used_percentage" => -5, "resets_at" => 1_787_994_000}
        }
      }

      assert {:error, {:malformed_window, "five_hour"}} = ClaudeStatusLineReceiver.parse(negative)

      over_100 = %{
        "rate_limits" => %{
          "seven_day" => %{"used_percentage" => 105, "resets_at" => 1_787_994_000}
        }
      }

      assert {:error, {:malformed_window, "seven_day"}} = ClaudeStatusLineReceiver.parse(over_100)
    end

    test "rejects invalid resets_at type" do
      bad_reset = %{
        "rate_limits" => %{
          "five_hour" => %{"used_percentage" => 25, "resets_at" => "not_a_valid_timestamp"}
        }
      }

      assert {:error, {:malformed_window, "five_hour"}} =
               ClaudeStatusLineReceiver.parse(bad_reset)
    end

    test "accepts valid ISO8601 resets_at string" do
      valid_iso = %{
        "rate_limits" => %{
          "five_hour" => %{"used_percentage" => 25, "resets_at" => "2026-08-30T12:00:00Z"}
        }
      }

      assert {:ok, parsed} = ClaudeStatusLineReceiver.parse(valid_iso)
      assert parsed["rate_limits"]["five_hour"]["resets_at"] == "2026-08-30T12:00:00Z"
    end
  end

  describe "parse/2 security and secret scanning" do
    test "rejects payload containing api_key or secret tokens immediately" do
      secret_map = %{
        "api_key" => "sk-ant-api03-12345678901234567890",
        "rate_limits" => %{"five_hour" => %{"used_percentage" => 10}}
      }

      assert {:error, :contains_secrets_or_forbidden_content} =
               ClaudeStatusLineReceiver.parse(secret_map)
    end

    test "rejects payload containing bearer authorization token" do
      bearer_map = %{
        "headers" => "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.e30.fake",
        "rate_limits" => %{}
      }

      assert {:error, :contains_secrets_or_forbidden_content} =
               ClaudeStatusLineReceiver.parse(bearer_map)
    end

    test "rejects payload containing forbidden prompt and response content keys" do
      forbidden_map = %{
        "prompt_messages" => ["Sensitive user instruction"],
        "rate_limits" => %{"five_hour" => %{"used_percentage" => 10}}
      }

      assert {:error, :contains_secrets_or_forbidden_content} =
               ClaudeStatusLineReceiver.parse(forbidden_map)

      transcript_map = %{
        "raw_transcript" => "Full conversation history...",
        "rate_limits" => %{}
      }

      assert {:error, :contains_secrets_or_forbidden_content} =
               ClaudeStatusLineReceiver.parse(transcript_map)
    end
  end

  describe "validate/1" do
    test "returns :ok for valid payload and {:error, reason} for invalid" do
      assert :ok =
               ClaudeStatusLineReceiver.validate(%{
                 "rate_limits" => %{"five_hour" => %{"used_percentage" => 50}}
               })

      assert {:error, :malformed_json} = ClaudeStatusLineReceiver.validate("not_json")
    end
  end
end
