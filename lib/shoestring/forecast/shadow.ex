defmodule Shoestring.Forecast.Shadow do
  @moduledoc """
  Versioned empirical forecasts for reports only. Never called by admission.

  A 99% upper order statistic is evaluated against strictly later held-out
  rows. Sparse, incompatible, unassignable or undercalibrated data retains the
  static policy. Passing this evaluator is not permission to enable routing.
  """
  alias Shoestring.Measurement.Dataset
  @class ~w(provider harness model effort adapter_version cli_version task_class)
  @minimum 100
  @coverage_target 0.99

  def class_fields, do: @class

  def report(dataset, at) do
    case valid_window(dataset, at) do
      {:ok, split} ->
        groups =
          dataset["rows"] |> Enum.filter(&classified?/1) |> Enum.group_by(&Map.take(&1, @class))

        if map_size(groups) > 100 do
          fallback("class_limit")
        else
          forecasts =
            groups
            |> Map.keys()
            |> Enum.sort_by(&Dataset.digest/1)
            |> Enum.map(&forecast(dataset, &1, at))

          %{
            "forecast_version" => 1,
            "mode" => "shadow",
            "policy_effect" => "none",
            "baseline_retained" => true,
            "dataset_digest" => Dataset.digest(dataset),
            "split_at" => iso(split),
            "evaluated_at" => iso(at),
            "class_count" => map_size(groups),
            "unclassified_rows" => Enum.count(dataset["rows"], &(not classified?(&1))),
            "unassignable_rows" => Enum.count(dataset["rows"], &(not eligible?(&1))),
            "forecast_count" => Enum.count(forecasts, &(&1["fallback_reason"] == nil)),
            "fallback_reason" => if(forecasts == [], do: "no_fully_classified_rows", else: nil),
            "forecasts" => forecasts
          }
        end

      {:error, reason} ->
        fallback(reason)
    end
  end

  def forecast(dataset, features, at) do
    with true <- classified?(features) || {:error, "missing_class_features"},
         {:ok, split} <- valid_window(dataset, at) do
      selected =
        Enum.filter(dataset["rows"], &(Map.take(&1, @class) == Map.take(features, @class)))

      available =
        Enum.filter(
          selected,
          &(eligible?(&1) and DateTime.compare(time(&1["available_at"]), at) == :lt)
        )

      {training, evaluation} =
        Enum.split_with(available, &(DateTime.compare(time(&1["available_at"]), split) == :lt))

      facts = %{
        "class_ref" => Dataset.digest(Map.take(features, @class)),
        "training_samples" => length(training),
        "evaluation_samples" => length(evaluation),
        "excluded_samples" => length(selected) - length(available),
        "minimum_training_samples" => @minimum,
        "minimum_evaluation_samples" => @minimum,
        "quantile" => @coverage_target,
        "coverage_target" => @coverage_target,
        "split_at" => iso(split),
        "evaluated_at" => iso(at),
        "false_admission_rate" => nil,
        "false_deferral_rate" => nil,
        "work_per_capacity_delta" => nil,
        "static_reservation_comparison" => "not_comparable_to_configured_concurrency_units"
      }

      if length(training) < @minimum or length(evaluation) < @minimum do
        Map.merge(fallback("insufficient_attributable_samples"), facts)
      else
        evaluate(training, evaluation, facts)
      end
    else
      {:error, reason} -> fallback(reason)
    end
  end

  defp evaluate(training, evaluation, facts) do
    values = Enum.sort(Enum.map(training, &value/1))
    # Finite-sample upper order statistic: ceil((n + 1) * q), not an
    # interpolated percentile that can understate the upper tail.
    rank = ceil((length(values) + 1) * @coverage_target)
    upper = Enum.at(values, min(rank, length(values)) - 1)
    under = Enum.count(evaluation, &(value(&1) > upper))
    coverage = 1 - under / length(evaluation)
    accepted = Enum.count(evaluation, &(&1["verified_outcome"] == "task_accepted"))
    calibrated? = coverage >= @coverage_target

    fallback(if(calibrated?, do: nil, else: "calibration_target_not_met"))
    |> Map.merge(facts)
    |> Map.merge(%{
      "candidate_interval_percent" => %{"lower" => 0, "upper" => upper},
      "forecast_interval_percent" =>
        if(calibrated?, do: %{"lower" => 0, "upper" => upper}, else: nil),
      "underprediction_count" => under,
      "underprediction_rate" => under / length(evaluation),
      "interval_coverage" => coverage,
      "task_acceptance_rate" => accepted / length(evaluation),
      "calibration_scope" => "observed_held_out_rows_only",
      "enforcement_eligible" => false
    })
  end

  defp fallback(reason) do
    %{
      "forecast_version" => 1,
      "mode" => "shadow",
      "policy_effect" => "none",
      "baseline_retained" => true,
      "fallback_reason" => reason,
      "forecast_interval_percent" => nil,
      "enforcement_eligible" => false
    }
  end

  defp valid_window(
         %{"dataset_version" => v, "extractor_version" => v, "rows" => rows, "split_at" => split},
         %DateTime{} = at
       )
       when v in [1, 2] and is_list(rows) and length(rows) <= 10_000 do
    cond do
      is_nil(time(split)) -> {:error, "explicit_chronological_split_required"}
      DateTime.compare(time(split), at) != :lt -> {:error, "invalid_chronological_window"}
      Enum.any?(rows, &(not valid_row?(&1))) -> {:error, "invalid_measurement_rows"}
      length(Enum.uniq_by(rows, & &1["run_id"])) != length(rows) -> {:error, "duplicate_run_rows"}
      true -> {:ok, time(split)}
    end
  end

  defp valid_window(_, _), do: {:error, "incompatible_dataset_or_clock"}

  defp valid_row?(row) when is_map(row) do
    available = time(row["available_at"])
    finished = time(row["finished_at"])

    match?({:ok, _}, Ecto.UUID.cast(row["run_id"])) and available != nil and
      is_map(row["capacity"]) and
      (row["finished_at"] == nil or
         (finished != nil and DateTime.compare(finished, available) != :gt))
  end

  defp valid_row?(_), do: false

  defp classified?(row) when is_map(row),
    do: Enum.all?(@class, &(is_binary(row[&1]) and row[&1] not in ["", "unknown", "default"]))

  defp classified?(_), do: false

  defp eligible?(row) do
    c = row["capacity"]

    row["training_eligible"] == true and c["assignable"] == true and
      c["attribution_confidence"] == "high" and c["external_usage"] == "isolated" and
      c["exclusion_reasons"] == [] and row["overlapping_run_count"] == 0 and
      row["finished_at"] != nil and is_number(c["consumption_percent"]) and
      c["consumption_percent"] >= 0 and c["consumption_percent"] <= 100
  end

  defp value(row), do: row["capacity"]["consumption_percent"]

  defp time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} -> time
      _ -> nil
    end
  end

  defp time(_), do: nil
  defp iso(time), do: DateTime.to_iso8601(time)
end
