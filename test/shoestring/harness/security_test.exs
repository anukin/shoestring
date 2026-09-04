defmodule Shoestring.Harness.SecurityTest do
  use ExUnit.Case, async: true

  alias Shoestring.Harness.Security

  describe "redact/1 extended secret shapes (F1/B3)" do
    test "redacts AWS access key IDs (AKIA/ASIA/AKIB)" do
      for key_id <- ["AKIAIOSFODNN7EXAMPLE", "ASIAIOSFODNN7EXAMPLE", "AKIBIOSFODNN7EXAMPLE"] do
        redacted = Security.redact("provider key #{key_id} leaked")

        refute redacted =~ key_id
        assert redacted =~ "[REDACTED_API_KEY]"
      end
    end

    test "redacts GitHub token prefixes (ghp_/gho_/ghu_/ghs_/ghr_/github_pat_)" do
      tokens = [
        "ghp_abcdefghijklmnopqrstuvwx1234567890",
        "gho_abcdefghijklmnopqrstuvwx1234567890",
        "ghu_abcdefghijklmnopqrstuvwx1234567890",
        "ghs_abcdefghijklmnopqrstuvwx1234567890",
        "ghr_abcdefghijklmnopqrstuvwx1234567890",
        "github_pat_abcDEF1234567890_xyzTOKEN"
      ]

      for token <- tokens do
        redacted = Security.redact("credential #{token} leaked")

        refute redacted =~ token,
               "expected GitHub-shaped token to be redacted: #{inspect(token)}"

        assert redacted =~ "[REDACTED_API_KEY]"
      end
    end

    test "redacts XML/tag-wrapped secret contents" do
      redacted = Security.redact("failure: <secret>hunter2-value</secret> end")

      refute redacted =~ "hunter2-value"
      assert redacted =~ "[REDACTED]"
    end

    test "redacts compound *-secret-* assignments the word-boundary regex misses" do
      redacted = Security.redact("config aws_secret_access_key=SUPERSECRETVALUE123 end")

      refute redacted =~ "SUPERSECRETVALUE123"
      assert redacted =~ "aws_secret_access_key=[REDACTED]"
    end

    test "redacts compound *-key assignments" do
      redacted = Security.redact("config custom_key=super-secret-value end")

      refute redacted =~ "super-secret-value"
      assert redacted =~ "custom_key=[REDACTED]"
    end

    test "does not redact plain words that merely end in key" do
      assert Security.redact("monkey: banana") == "monkey: banana"
      assert Security.redact("turkey dinner") == "turkey dinner"
    end

    test "leaves non-secret operational prose untouched" do
      assert Security.redact("provider refused") == "provider refused"

      assert Security.redact("stale_observation: capacity probe overdue") ==
               "stale_observation: capacity probe overdue"
    end
  end

  describe "capacity_forbidden_value?/1 extended detection" do
    test "flags the new shapes for capacity observation validation" do
      assert Security.capacity_forbidden_value?("x AKIAIOSFODNN7EXAMPLE y")
      assert Security.capacity_forbidden_value?("x ghp_abcdefgh12345678 y")
      assert Security.capacity_forbidden_value?("x <secret>abc</secret> y")
      assert Security.capacity_forbidden_value?("x aws_secret_access_key=abc y")
      assert Security.capacity_forbidden_value?("x custom_key=abc y")
    end

    test "does not flag benign prose" do
      refute Security.capacity_forbidden_value?("provider refused")
      refute Security.capacity_forbidden_value?("monkey: banana")
      refute Security.capacity_forbidden_value?("stale_observation: capacity probe overdue")
    end
  end
end
