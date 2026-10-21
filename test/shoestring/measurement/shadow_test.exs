defmodule Shoestring.Forecast.ShadowTest do
  use ExUnit.Case, async: true
  alias Shoestring.Forecast.Shadow
  alias Shoestring.Measurement.Dataset
  alias Shoestring.Test.MeasurementFixtures, as: F

  @features %{
    "provider" => "codex",
    "harness" => "synthetic",
    "model" => "synthetic-model",
    "effort" => "high",
    "adapter_version" => "1",
    "cli_version" => "1.0.0",
    "task_class" => "code"
  }

  test "held-out interval calibration is distinct from task success and never changes policy" do
    result = Shadow.forecast(dataset(), @features, F.time(1000))
    assert result["forecast_interval_percent"] == %{"lower" => 0, "upper" => 5.0}
    assert result["training_samples"] == 100
    assert result["evaluation_samples"] == 100
    assert result["interval_coverage"] == 1.0
    assert result["underprediction_rate"] == 0.0
    assert result["task_acceptance_rate"] == 0.0
    assert result["policy_effect"] == "none"
    assert result["baseline_retained"]
    refute result["enforcement_eligible"]
    assert result["false_admission_rate"] == nil
    assert result["false_deferral_rate"] == nil
  end

  test "version/model drift cannot reuse another cohort" do
    for field <- ~w(model cli_version adapter_version effort) do
      result = Shadow.forecast(dataset(), Map.put(@features, field, "different"), F.time(1000))
      assert result["fallback_reason"] == "insufficient_attributable_samples"
      assert result["forecast_interval_percent"] == nil
      assert result["baseline_retained"]
    end
  end

  test "coverage failures withhold the forecast and report exact underprediction" do
    data = dataset()

    rows =
      Enum.map(data["rows"], fn row ->
        if row["available_at"] >= DateTime.to_iso8601(F.time(200)),
          do: put_in(row, ["capacity", "consumption_percent"], 8.0),
          else: row
      end)

    result = Shadow.forecast(%{data | "rows" => rows}, @features, F.time(1000))
    assert result["fallback_reason"] == "calibration_target_not_met"
    assert result["candidate_interval_percent"]["upper"] == 5.0
    assert result["forecast_interval_percent"] == nil
    assert result["underprediction_count"] == 100
    assert result["interval_coverage"] == 0.0
  end

  test "future evidence cannot fill a sparse training or evaluation cohort" do
    data = dataset()
    result = Shadow.forecast(data, @features, F.time(299))
    assert result["evaluation_samples"] == 99
    assert result["excluded_samples"] == 1
    assert result["fallback_reason"] == "insufficient_attributable_samples"
    rows = Enum.map(data["rows"], &Map.put(&1, "available_at", DateTime.to_iso8601(F.time(9999))))
    result = Shadow.forecast(%{data | "rows" => rows}, @features, F.time(1000))
    assert result["training_samples"] == 0
    assert result["evaluation_samples"] == 0
  end

  test "external uncertainty, concurrent use and nonassignable labels are excluded" do
    for update <- [
          fn row -> put_in(row, ["capacity", "external_usage"], "unknown") end,
          fn row -> put_in(row, ["capacity", "assignable"], false) end,
          fn row -> put_in(row, ["capacity", "attribution_confidence"], "low") end,
          fn row -> Map.put(row, "overlapping_run_count", 1) end,
          fn row -> Map.put(row, "training_eligible", false) end
        ] do
      data = dataset()

      result =
        Shadow.forecast(
          %{data | "rows" => Enum.map(data["rows"], update)},
          @features,
          F.time(1000)
        )

      assert result["training_samples"] == 0
      assert result["evaluation_samples"] == 0
      assert result["excluded_samples"] == 200
      assert result["forecast_interval_percent"] == nil
    end
  end

  test "real v1 extraction stays in fallback, with honest missing-class and attribution counts" do
    assert {:ok, measurements} = Dataset.build(F.history().events, split_at: F.time(100))
    report = Shadow.report(measurements, F.time(1000))
    assert report["forecast_count"] == 0
    assert report["unclassified_rows"] == 1
    assert report["unassignable_rows"] == 1
    assert report["fallback_reason"] == "no_fully_classified_rows"
    assert report["baseline_retained"]
  end

  test "reports reproduce regardless of cohort input order and never echo class content" do
    data = dataset()
    report = Shadow.report(data, F.time(1000))
    shuffled = Shadow.report(%{data | "rows" => Enum.reverse(data["rows"])}, F.time(1000))
    assert report["forecasts"] == shuffled["forecasts"]
    assert report["forecast_count"] == shuffled["forecast_count"]
    assert report == Shadow.report(data, F.time(1000))

    refute Jason.encode!(report) =~ "synthetic-model"
    assert report["forecast_count"] == 1

    assert Shadow.forecast(data, %{@features | "model" => nil}, F.time(1000))["fallback_reason"] ==
             "missing_class_features"
  end

  test "unsupported data, duplicate runs and absent or reversed chronology fail closed" do
    data = dataset()

    assert Shadow.forecast(%{data | "dataset_version" => 99}, @features, F.time(1000))[
             "fallback_reason"
           ] == "incompatible_dataset_or_clock"

    assert Shadow.forecast(%{data | "split_at" => nil}, @features, F.time(1000))[
             "fallback_reason"
           ] == "explicit_chronological_split_required"

    assert Shadow.forecast(data, @features, F.time(50))["fallback_reason"] ==
             "invalid_chronological_window"

    assert Shadow.forecast(
             %{data | "rows" => [hd(data["rows"]) | data["rows"]]},
             @features,
             F.time(1000)
           )["fallback_reason"] == "duplicate_run_rows"

    assert Shadow.forecast(%{data | "rows" => [%{}]}, @features, F.time(1000))["fallback_reason"] ==
             "invalid_measurement_rows"
  end

  test "CLI requires an explicit valid chronological window and refuses enable flags" do
    for args <- [
          ["report"],
          ["report", "--enable"],
          ["report", "--at", "tomorrow", "--split-at", "yesterday"],
          ["report", "--at", "2026-10-01T00:00:00Z", "--split-at", "2026-10-02T00:00:00Z"]
        ] do
      assert_raise Mix.Error, ~r/Invalid arguments/, fn ->
        Mix.Tasks.Shoestring.Forecasts.run(args)
      end
    end
  end

  test "finite-sample upper order statistic retains the training maximum at 100 samples" do
    data = dataset()

    rows =
      data["rows"]
      |> Enum.with_index()
      |> Enum.map(fn {row, index} ->
        put_in(
          row,
          ["capacity", "consumption_percent"],
          if(index < 100, do: index + 1, else: 100)
        )
      end)

    result = Shadow.forecast(%{data | "rows" => rows}, @features, F.time(1000))
    assert result["forecast_interval_percent"]["upper"] == 100
    assert result["interval_coverage"] == 1.0
  end

  test "a future outcome cannot masquerade as evidence available before the split" do
    data = dataset()
    [first | rest] = data["rows"]
    future = Map.put(first, "finished_at", DateTime.to_iso8601(F.time(2000)))
    result = Shadow.forecast(%{data | "rows" => [future | rest]}, @features, F.time(1000))
    assert result["fallback_reason"] == "invalid_measurement_rows"
    assert result["forecast_interval_percent"] == nil
  end

  defp dataset do
    rows =
      for index <- 0..199 do
        @features
        |> Map.merge(%{
          "run_id" => Ecto.UUID.generate(),
          "available_at" =>
            DateTime.to_iso8601(F.time(index + if(index < 100, do: 0, else: 100))),
          "finished_at" => DateTime.to_iso8601(F.time(index)),
          "training_eligible" => true,
          "overlapping_run_count" => 0,
          "verified_outcome" => "unverified",
          "capacity" => %{
            "assignable" => true,
            "attribution_confidence" => "high",
            "external_usage" => "isolated",
            "exclusion_reasons" => [],
            "consumption_percent" => 5.0
          }
        })
      end

    %{
      "dataset_version" => 1,
      "extractor_version" => 1,
      "split_at" => DateTime.to_iso8601(F.time(150)),
      "rows" => rows
    }
  end
end
