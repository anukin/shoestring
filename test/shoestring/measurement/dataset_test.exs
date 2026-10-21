defmodule Shoestring.Measurement.DatasetTest do
  use ExUnit.Case, async: true
  alias Shoestring.Measurement.Dataset
  alias Shoestring.Test.MeasurementFixtures, as: F

  test "rebuild is byte-identical despite input order and traces every row to events" do
    f = F.history()
    assert {:ok, first} = Dataset.build(f.events)
    assert {:ok, second} = Dataset.build(Enum.reverse(f.events))
    assert Dataset.encode(first) == Dataset.encode(second)
    assert first["source_event_count"] == 6
    [row] = first["rows"]
    assert row["run_id"] == f.run_id
    assert row["duration_ms"] == 8_000
    assert row["result"] == "completed"
    assert row["verified_outcome"] == "unverified"
    assert row["lease"]["response_budget"] == 5
    assert row["lease"]["tool_reserve"] == 2
    assert row["cli_version"] == "0.163.0"
    assert Enum.map(row["source_events"], & &1["event_id"]) == Enum.map(f.events, & &1.id)

    assert row["capacity"]["observed_change_percent"] == [
             %{"window" => 1, "observed_change" => 2.0}
           ]

    assert row["capacity"]["exclusion_reasons"] == ["external_usage_unknown"]
    refute row["training_eligible"]
    refute row["capacity"]["assignable"]
    assert row["capacity"]["consumption_percent"] == nil
    refute first["quality"]["forecast_training_ready"]
  end

  test "privacy allowlist excludes text, paths, sessions and nested metadata while retaining numeric features" do
    f = F.history()

    events =
      Enum.map(f.events, fn event ->
        case event.type do
          "run.requested" ->
            %{
              event
              | payload:
                  event.payload
                  |> Map.put("prompt", "PRIVATE_PROMPT_MARKER")
                  |> Map.put("workspace_ref", "/Users/synthetic/private-repo")
                  |> Map.put("extensions", %{"fixture:private" => "PRIVATE_EXTENSION_MARKER"})
            }

          "run.running" ->
            %{
              event
              | payload:
                  Map.put(event.payload, "provider_session_id", "synthetic-session-private")
            }

          "lease.proposed" ->
            %{
              event
              | payload: put_in(event.payload, ["reserves", "extra"], "PRIVATE_NESTED_MARKER")
            }

          _ ->
            event
        end
      end)

    assert {:ok, dataset} = Dataset.build(events)
    bytes = Dataset.encode(dataset)

    for private <- [
          "PRIVATE_PROMPT_MARKER",
          "PRIVATE_EXTENSION_MARKER",
          "PRIVATE_NESTED_MARKER",
          "/Users/synthetic",
          "synthetic-session-private",
          "synthetic-account"
        ],
        do: refute(bytes =~ private)

    assert bytes =~ "response_budget"
    assert hd(dataset["rows"])["lease"]["response_budget"] == 5
    assert hd(dataset["rows"])["provider"] == "codex"
    assert hd(dataset["rows"])["capacity"]["before"]["scope_ref"] =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "unknown adapters and version text never become raw features" do
    f = F.history()

    events =
      Enum.map(f.events, fn e ->
        case e.type do
          "run.requested" ->
            %{e | payload: Map.put(e.payload, "provider_id", "PRIVATE_ADAPTER_MARKER")}

          "capacity.snapshot_observed" ->
            %{
              e
              | payload:
                  put_in(
                    e.payload,
                    ["extensions", "capacity:cli_version"],
                    "PRIVATE_VERSION_MARKER"
                  )
            }

          _ ->
            e
        end
      end)

    assert {:ok, dataset} = Dataset.build(events)
    [row] = dataset["rows"]
    assert row["provider"] == "unknown"
    assert row["harness"] == "unknown"
    assert row["cli_version"] == nil
    refute Dataset.encode(dataset) =~ "PRIVATE_ADAPTER_MARKER"
    refute Dataset.encode(dataset) =~ "PRIVATE_VERSION_MARKER"
  end

  test "overlapping external-to-goal runs are contamination, never consumption labels" do
    a = F.history()
    b = F.history()
    assert {:ok, dataset} = Dataset.build(a.events ++ b.events)

    for row <- dataset["rows"] do
      assert row["overlapping_run_count"] == 1
      assert "concurrent_shoestring_runs" in row["capacity"]["exclusion_reasons"]
      assert "external_usage_unknown" in row["capacity"]["exclusion_reasons"]
      refute row["training_eligible"]
    end
  end

  test "a missing after observation is visible and no later run result is invented" do
    f = F.history()
    events = Enum.reject(f.events, &(&1.sequence >= 5))
    assert {:ok, dataset} = Dataset.build(events, split_at: F.time(10))
    [row] = dataset["rows"]
    assert row["result"] == "unfinished"
    assert row["finished_at"] == nil
    assert row["duration_ms"] == nil
    assert row["split"] == "unfinished"
    assert "missing_after_observation" in row["capacity"]["exclusion_reasons"]
    assert "incomplete_run_boundaries" in row["capacity"]["exclusion_reasons"]
  end

  test "chronological split waits for post-run evidence, equality belongs to evaluation" do
    f = F.history()
    assert {:ok, dataset} = Dataset.build(f.events, split_at: F.time(10))
    assert hd(dataset["rows"])["split"] == "evaluation"
    assert {:ok, dataset} = Dataset.build(f.events, split_at: F.time(11))
    assert hd(dataset["rows"])["split"] == "evaluation"
    assert hd(dataset["rows"])["available_at"] == DateTime.to_iso8601(F.time(11))
    assert {:ok, dataset} = Dataset.build(f.events, split_at: F.time(12))
    assert hd(dataset["rows"])["split"] == "train"
    assert {:error, :invalid_split_timestamp} = Dataset.build(f.events, split_at: "tomorrow")
  end

  test "resets, negative deltas and CLI changes are excluded as incomparable" do
    for update <- [
          fn p ->
            put_in(p, ["windows", "items"], [
              %{
                "kind" => "primary",
                "state" => "observed",
                "used_percent" => 5.0,
                "reset_at" => DateTime.to_iso8601(F.time(3600))
              }
            ])
          end,
          fn p ->
            put_in(p, ["windows", "items"], [
              %{
                "kind" => "primary",
                "state" => "observed",
                "used_percent" => 12.0,
                "reset_at" => DateTime.to_iso8601(F.time(7200))
              }
            ])
          end,
          fn p -> put_in(p, ["extensions", "capacity:cli_version"], "0.164.0") end
        ] do
      f = F.history()

      events =
        Enum.map(f.events, fn e ->
          if e.sequence == 6, do: %{e | payload: update.(e.payload)}, else: e
        end)

      assert {:ok, dataset} = Dataset.build(events)
      capacity = hd(dataset["rows"])["capacity"]
      assert "incomparable_windows_or_versions" in capacity["exclusion_reasons"]
      assert capacity["observed_change_percent"] == nil
    end
  end

  test "after readings from another scope cannot be paired" do
    f = F.history()

    events =
      Enum.map(f.events, fn e ->
        if e.sequence == 6,
          do: %{e | payload: Map.put(e.payload, "scope", "different-account")},
          else: e
      end)

    assert {:ok, dataset} = Dataset.build(events)
    assert hd(dataset["rows"])["capacity"]["after"] == nil
  end

  test "stale before and late after boundaries are explicit" do
    f = F.history()

    events =
      Enum.map(f.events, fn e ->
        cond do
          e.sequence == 4 ->
            %{e | occurred_at: F.time(70)}

          e.sequence == 5 ->
            %{e | occurred_at: F.time(80)}

          e.sequence == 6 ->
            %{
              e
              | occurred_at: F.time(150),
                payload: F.capacity(e.payload["snapshot_id"], 150, 12.0)
            }

          true ->
            e
        end
      end)

    assert {:ok, dataset} = Dataset.build(events)
    reasons = hd(dataset["rows"])["capacity"]["exclusion_reasons"]
    assert "before_observation_not_fresh" in reasons
    assert "after_observation_too_late" in reasons
  end

  test "unsupported history, sequence gaps and duplicate IDs fail without echoing payload" do
    f = F.history()
    [first | rest] = f.events
    assert {:error, :unsupported_history} = Dataset.build([%{first | schema_version: 99} | rest])
    assert {:error, :history_sequence_gap} = Dataset.build(rest)
    assert {:error, :duplicate_event_identity} = Dataset.build([first | f.events])
    assert {:error, :invalid_history} = Dataset.build([%{first | payload: %{}} | rest])
  end

  test "empty histories report no training data, not success or savings" do
    assert {:ok, dataset} = Dataset.build([])
    assert dataset["rows"] == []
    assert dataset["source_watermarks"] == []
    assert dataset["quality"]["run_count"] == 0
    assert dataset["quality"]["assignable_consumption_rows"] == 0
    refute dataset["quality"]["forecast_training_ready"]
  end

  test "size limits refuse a partial history instead of silently truncating it" do
    [event | _] = F.history().events

    assert {:error, :measurement_event_limit} =
             Dataset.build(List.duplicate(event, Dataset.max_events() + 1))
  end

  test "a lease cannot pair a different provider's snapshot" do
    f = F.history()

    events =
      Enum.map(f.events, fn e ->
        if e.sequence == 1,
          do: %{e | payload: put_in(e.payload, ["source", "provider_id"], "claude")},
          else: e
      end)

    assert {:ok, dataset} = Dataset.build(events)
    capacity = hd(dataset["rows"])["capacity"]
    assert capacity["before"] == nil
    assert "missing_before_observation" in capacity["exclusion_reasons"]
  end

  test "negative elapsed time is unknown rather than fabricated zero duration" do
    f = F.history()

    events =
      Enum.map(f.events, fn e ->
        if e.sequence == 5, do: %{e | occurred_at: F.time(1)}, else: e
      end)

    assert {:ok, dataset} = Dataset.build(events)
    [row] = dataset["rows"]
    assert row["duration_ms"] == nil
    assert "inconsistent_run_timestamps" in row["capacity"]["exclusion_reasons"]
  end
end
