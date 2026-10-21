defmodule Shoestring.Diagnostics.BundleTest do
  use ExUnit.Case, async: true
  alias Shoestring.Diagnostics.Bundle
  alias Shoestring.Test.MeasurementFixtures, as: Fixtures

  test "projection excludes secrets, absolute paths, source and identities while retaining compatibility" do
    fixture = Fixtures.history()
    [capacity | rest] = fixture.events

    sensitive =
      "Bearer synthetic-credential-value /Users/synthetic/projects/private /home/synthetic/.auth"

    payload = capacity.payload

    payload =
      payload |> Map.put("reason", sensitive) |> Map.put("scope", "private-account-marker")

    payload = put_in(payload, ["extensions", "private"], sensitive)
    events = [%{capacity | actor: sensitive, payload: payload} | rest]
    assert {:ok, bundle} = Bundle.build(events, metadata(), length(events))
    bytes = Bundle.encode(bundle)

    for forbidden <- [
          sensitive,
          "synthetic-credential-value",
          "private-account-marker",
          "/Users/",
          "/home/",
          "Synthetic task text",
          "workspace/fixture",
          fixture.goal_id,
          fixture.task_id,
          fixture.run_id,
          capacity.id,
          capacity.payload["snapshot_id"],
          "secret-runtime-marker"
        ] do
      refute bytes =~ forbidden
    end

    assert bundle["runtime"]["shoestring"] == "0.1.0"
    assert bundle["runtime"]["os"] == "macos"
    assert bundle["events"] |> hd() |> get_in(["summary", "cli_version"]) == "0.163.0"
    assert bundle["events"] |> hd() |> get_in(["summary", "support_tier"]) == "proactive"
    assert Enum.map(bundle["events"], & &1["sequence"]) == [1, 2, 3, 4, 5, 6]

    assert Enum.map(bundle["events"], & &1["relative_ms"]) == [
             0,
             1_000,
             1_000,
             2_000,
             10_000,
             11_000
           ]

    assert Enum.all?(bundle["events"], &(&1["goal"] == "goal-1"))
    assert Enum.find(bundle["events"], &(&1["type"] == "run.completed"))["run"] == "run-1"
  end

  test "every unrestricted payload field is dropped, including disguised provider/version values" do
    fixture = Fixtures.history()
    [event | _] = fixture.events
    marker = "token=synthetic-cookie /Users/synthetic/hidden"

    payload = %{
      "source" => %{"provider_id" => marker, "adapter_id" => marker},
      "extensions" => %{"capacity:cli_version" => marker},
      "support_tier" => marker,
      "compatibility_state" => marker,
      "capacity_state" => marker,
      "reason" => marker,
      "nested" => %{"source_code" => marker}
    }

    assert {:ok, bundle} = Bundle.build([%{event | payload: payload}], metadata(), 1)
    summary = hd(bundle["events"])["summary"]
    assert summary["provider"] == "unknown"
    assert summary["cli_version"] == nil
    refute Bundle.encode(bundle) =~ marker
    assert hd(bundle["events"])["type"] == "capacity.snapshot_observed"
    assert hd(bundle["events"])["schema_version"] == 2
  end

  test "policy explanations come from local templates and known codes, never stored prose" do
    fixture = Fixtures.history()

    payload = %{
      "result" => "require_confirmation",
      "reason_code" => "stale_observation",
      "explanation" => "password=synthetic-private-value /home/synthetic/repo",
      "candidate" => %{
        "provider_id" => "codex",
        "support_tier" => "proactive",
        "compatibility_state" => "compatible"
      }
    }

    event =
      Fixtures.event(
        fixture.goal_id,
        fixture.task_id,
        fixture.run_id,
        7,
        "admission.decided",
        12,
        payload
      )

    assert {:ok, bundle} = Bundle.build([event], metadata(), 1)
    summary = hd(bundle["events"])["summary"]
    assert summary["reason"] == "stale_observation"
    assert summary["result"] == "require_confirmation"
    assert summary["provider"] == "codex"
    assert summary["explanation"] =~ "static admission constraint"
    refute Bundle.encode(bundle) =~ "synthetic-private-value"

    event = %{event | payload: %{payload | "reason_code" => "custom-secret-marker"}}
    assert {:ok, unknown} = Bundle.build([event], metadata(), 1)
    assert hd(unknown["events"])["summary"]["reason"] == "unknown"
    refute Bundle.encode(unknown) =~ "custom-secret-marker"
  end

  test "waiting, typed errors and gate results retain bounded useful fields but no output" do
    fixture = Fixtures.history()

    events = [
      Fixtures.event(
        fixture.goal_id,
        fixture.task_id,
        fixture.run_id,
        7,
        "cobbler.plan.admission.waiting",
        12,
        %{
          "provider_id" => "claude",
          "attempt" => 2,
          "reason" => "no_observation_for_provider",
          "scope" => "private-scope"
        }
      ),
      Fixtures.event(
        fixture.goal_id,
        fixture.task_id,
        fixture.run_id,
        8,
        "harness.event_recorded",
        13,
        %{
          "kind" => "error",
          "error" => %{
            "category" => "transport",
            "message" => "private-output",
            "code" => "private-code"
          }
        }
      ),
      Fixtures.event(
        fixture.goal_id,
        fixture.task_id,
        fixture.run_id,
        9,
        "cobbler.plan.gate.completed",
        14,
        %{
          "result" => "failed",
          "kind" => "test",
          "duration_ms" => 42,
          "required" => true,
          "exit_status" => 1,
          "reason" => "private-output"
        }
      )
    ]

    assert {:ok, bundle} = Bundle.build(events, metadata(), 3)
    [waiting, error, gate] = Enum.map(bundle["events"], & &1["summary"])
    assert waiting["explanation"] == "Admission is waiting for a provider capacity observation."
    assert waiting["attempt"] == 2
    assert error["error_category"] == "transport"

    assert gate == %{
             "result" => "failed",
             "kind" => "test",
             "duration_ms" => 42,
             "required" => true,
             "exit_status" => 1
           }

    for marker <- ~w(private-scope private-output private-code),
        do: refute(Bundle.encode(bundle) =~ marker)
  end

  test "unknown event type and version retain honest schema status without interpreting payload" do
    fixture = Fixtures.history()
    [event | _] = fixture.events
    unknown_type = %{event | type: "/Users/synthetic/custom-secret-type"}
    unknown_version = %{event | id: Ecto.UUID.generate(), sequence: 7, schema_version: 999}
    assert {:ok, bundle} = Bundle.build([unknown_type, unknown_version], metadata(), 2)

    assert Enum.all?(
             bundle["events"],
             &(&1["schema_registered"] == false and &1["summary"] == %{})
           )

    assert Enum.any?(bundle["events"], &(&1["type"] == "unregistered"))
    assert Enum.any?(bundle["events"], &(&1["schema_version"] == 999))
    refute Bundle.encode(bundle) =~ "custom-secret-type"
  end

  test "runtime, config, health and fixture metadata are independently allowlisted" do
    input = metadata()
    input = put_in(input, ["runtime", "elixir"], "/Users/synthetic/secret-version")
    input = put_in(input, ["configuration", "api_cap_microusd"], "token=synthetic-key")
    input = put_in(input, ["health", "sqlite_version"], "synthetic-password")
    input = put_in(input, ["compatibility_fixtures", "private-fixture"], "/home/synthetic/.auth")
    assert {:ok, bundle} = Bundle.build([], input, 0)
    assert bundle["runtime"]["elixir"] == nil
    assert bundle["configuration"]["api_cap_microusd"] == nil
    assert bundle["configuration"]["forecast_enforcement"] == false
    assert bundle["health"]["sqlite_version"] == nil
    assert bundle["health"]["provider_authentication"] == "not_checked"
    assert bundle["compatibility_fixtures"]["codex-initialize-v1"] == String.duplicate("a", 64)
    refute Bundle.encode(bundle) =~ "synthetic-"
    refute Bundle.encode(bundle) =~ "private-fixture"
    refute Bundle.encode(bundle) =~ "/home/"
  end

  test "deterministic projection and preview bind every exported byte" do
    fixture = Fixtures.history()
    assert {:ok, first} = Bundle.build(fixture.events, metadata(), 20)
    assert {:ok, second} = Bundle.build(Enum.reverse(fixture.events), metadata(), 20)
    assert first == second
    preview = Bundle.preview(first)
    bytes = Bundle.encode(first)
    assert preview["confirmation_sha256"] == Bundle.digest(bytes)
    assert preview["bytes"] == byte_size(bytes)
    assert preview["manifest"]["omitted_events"] == 14
    assert preview["manifest"]["upload"] == "none"
    assert "prompts" in preview["manifest"]["excluded"]
    assert preview["bundle"] == first
  end

  test "oversized source and selections fail closed without silently truncating" do
    fixture = Fixtures.history()
    [event | _] = fixture.events

    assert {:error, :diagnostic_event_limit} =
             Bundle.build(List.duplicate(event, 201), metadata(), 201)

    assert {:error, :invalid_diagnostic_selection} = Bundle.build([event], metadata(), 0)

    event = %{
      event
      | payload: %{"prompt" => String.duplicate("x", Bundle.max_source_bytes() + 1)}
    }

    assert {:error, :diagnostic_source_limit} = Bundle.build([event], metadata(), 1)
  end

  defp metadata do
    %{
      "runtime" => %{
        "shoestring" => "0.1.0",
        "elixir" => "1.19.5",
        "otp" => "28",
        "os" => "macos",
        "architecture" => "arm64",
        "terminal_protocol" => 1,
        "release" => "development",
        "private" => "secret-runtime-marker"
      },
      "configuration" => %{
        "forecast_enforcement" => false,
        "api_enabled" => false,
        "api_cap_microusd" => 0,
        "capacity_monitors" => %{"claude" => false, "codex" => false}
      },
      "health" => %{
        "repository" => "readable",
        "sqlite_version" => "3.53.0",
        "state_directory" => "read_write"
      },
      "compatibility_fixtures" => %{"codex-initialize-v1" => String.duplicate("a", 64)}
    }
  end
end
