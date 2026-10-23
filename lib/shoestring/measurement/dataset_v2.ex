defmodule Shoestring.Measurement.DatasetV2 do
  @moduledoc """
  Rebuildable v2 measurements: v1 rows plus attribution from operator-attested
  collection windows and inference-free readings taken immediately around each
  run (`Shoestring.Measurement.Brackets`).

  A row becomes a calibration example only when every condition holds: its
  class (provider, harness, model, effort, Shoestring and CLI versions, task
  class) was recorded before dispatch; fresh comparable readings bracket the
  run tightly; both readings fall in one attested window that was not closed
  for external use and shows no unexplained change between bracketed runs; and
  no other Shoestring run of the provider overlapped. Anything else keeps the
  row unassignable with explicit reasons. v1 output is unchanged.
  """
  alias Shoestring.Measurement.{Collection, Dataset}

  @version 2
  @max_bracket_gap_seconds 120
  @binding "shoestring.agent:binding"

  def version, do: @version
  def max_bracket_gap_seconds, do: @max_bracket_gap_seconds

  def build(events, opts \\ []) when is_list(events) do
    with {:ok, v1} <- Dataset.build(events, opts) do
      events = Enum.sort_by(events, &{&1.goal_id, &1.sequence})
      windows = Collection.windows(events)
      index = index(events)
      split_at = v1["split_at"] && datetime(v1["split_at"])

      rows =
        v1["rows"]
        |> Enum.map(&attribute(&1, index, windows))
        |> overlaps()
        |> contaminate(windows)
        |> Enum.map(&finalize(&1, split_at))

      {:ok,
       v1
       |> Map.merge(%{
         "dataset_version" => @version,
         "extractor_version" => @version,
         "rows" => rows,
         "collection_windows" => Enum.map(windows, &window_view/1),
         "quality" => quality(rows, windows)
       })}
    end
  end

  # -- Indexing ---------------------------------------------------------------

  defp index(events) do
    %{
      requests:
        for(e <- events, e.type == "run.requested", into: %{}, do: {e.payload["run_id"], e}),
      dispatched:
        for(
          e <- events,
          e.type == "cobbler.plan.task.dispatched",
          into: %{},
          do: {e.payload["run_id"], e}
        ),
      revisions:
        for(
          e <- events,
          e.type == "cobbler.plan.revision.created",
          into: %{},
          do: {{e.goal_id, e.payload["revision_number"]}, e}
        ),
      by_id: for(e <- events, e.type in Collection.event_types(), into: %{}, do: {e.id, e}),
      brackets:
        for(
          e <- events,
          e.type == "capacity.snapshot_observed",
          is_binary(e.idempotency_key),
          String.starts_with?(e.idempotency_key, "measurement-"),
          into: %{},
          do: {{e.goal_id, e.idempotency_key}, e}
        )
    }
  end

  # -- Per-row attribution ----------------------------------------------------

  defp attribute(row, index, windows) do
    # Every reference below is pre-dispatch or bracket evidence in canonical
    # history; nothing is inferred from prompts, outputs or the checkout.
    request = index.requests[row["run_id"]]
    dispatched = index.dispatched[row["run_id"]]
    binding = request && get_in(request.payload, ["extensions", @binding])
    context = dispatched && context(dispatched)
    before = context && index.brackets[{row["goal_id"], "measurement-before:" <> context}]
    after_reading = context && index.brackets[{row["goal_id"], "measurement-after:" <> context}]

    revision =
      dispatched && index.revisions[{row["goal_id"], dispatched.payload["revision_number"]}]

    window = window(windows, row["provider"], before, after_reading)

    row =
      Map.merge(row, %{
        "model" => text(binding && binding["model"]),
        "effort" => text(binding && binding["effort"]),
        "adapter_version" => text(extension(before, "measurement:shoestring_version")),
        "cli_version" => numeric_version(extension(before, "capacity:cli_version")),
        "task_class" => task_class(revision, dispatched)
      })

    window_events =
      if window,
        do: [index.by_id[window.opened_event_id], index.by_id[window.closed_event_id]],
        else: []

    refs = [dispatched, revision, before, after_reading | window_events]

    {row,
     %{
       before: before,
       after: after_reading,
       window: window,
       context: context,
       refs: Enum.reject(refs, &is_nil/1)
     }}
  end

  defp context(dispatched) do
    p = dispatched.payload
    "#{p["execution_id"]}:#{p["plan_task_id"]}:#{p["attempt"]}"
  end

  defp window(_windows, _provider, nil, _after), do: nil
  defp window(_windows, _provider, _before, nil), do: nil

  defp window(windows, provider, before, after_reading) do
    scope = before.payload["scope"]
    first = Collection.open_at(windows, provider, scope, observed_at(before))
    last = Collection.open_at(windows, provider, scope, observed_at(after_reading))
    if first && last && first.window_id == last.window_id, do: first
  end

  defp task_class(nil, _dispatched), do: nil

  defp task_class(revision, dispatched) do
    # Plan content is stored as its canonical JSON text.
    tasks =
      case revision.payload["plan_content"] do
        content when is_binary(content) ->
          case Jason.decode(content) do
            {:ok, %{"tasks" => tasks}} when is_list(tasks) -> tasks
            _ -> []
          end

        %{"tasks" => tasks} when is_list(tasks) ->
          tasks

        _ ->
          []
      end

    case Enum.find(tasks, &(&1["id"] == dispatched.payload["plan_task_id"])) do
      %{"gates" => gates} when is_list(gates) and gates != [] ->
        names = gates |> Enum.map(& &1["gate"]) |> Enum.uniq() |> Enum.sort()

        if Enum.all?(names, &(is_binary(&1) and Regex.match?(~r/\A[a-z0-9_:.-]{1,80}\z/, &1))),
          do: "gates:" <> Enum.join(names, "+"),
          else: nil

      _ ->
        nil
    end
  end

  # -- Capacity attribution ---------------------------------------------------

  defp capacity(row, facts) do
    %{before: before, after: after_reading, window: window} = facts
    started = datetime(row["started_at"])
    finished = datetime(row["finished_at"])

    reasons =
      []
      |> add(
        row["provider"] not in Shoestring.Measurement.Brackets.readable_providers(),
        "provider_has_no_inference_free_reading"
      )
      |> add(is_nil(facts.context), "not_a_plan_dispatch")
      |> add(is_nil(before), "missing_before_reading")
      |> add(is_nil(after_reading), "missing_after_reading")
      |> add(is_nil(started) or is_nil(finished), "incomplete_run_boundaries")
      |> add(
        before && started && not before_ok?(before, started),
        "before_reading_not_immediately_before_run"
      )
      |> add(
        after_reading && finished && not after_ok?(after_reading, finished),
        "after_reading_not_immediately_after_run"
      )
      |> add(before && after_reading && is_nil(window), "outside_attested_collection_window")
      |> add(
        window && window.close_reason == "external_use_reported",
        "collection_window_external_use_reported"
      )
      |> add(
        before && after_reading && not comparable?(before, after_reading),
        "incomparable_readings"
      )
      |> add(missing_class?(row), "missing_class_features")

    changes =
      if before && after_reading && comparable?(before, after_reading),
        do: changes(before, after_reading)

    %{
      "basis" => "attested_window_bracketed_explicit_reads",
      "before" => observation(before),
      "after" => observation(after_reading),
      "collection_window_id" => window && window.window_id,
      "observed_change_percent" => changes,
      "consumption_percent" => nil,
      "consumption_window_minutes" => nil,
      "assignable" => false,
      "attribution_confidence" => "none",
      "external_usage" => "unknown",
      "exclusion_reasons" => reasons
    }
  end

  defp before_ok?(before, started) do
    observed = observed_at(before)

    observed != nil and DateTime.compare(observed, started) != :gt and
      DateTime.diff(started, observed) <= @max_bracket_gap_seconds
  end

  defp after_ok?(after_reading, finished) do
    observed = observed_at(after_reading)

    observed != nil and DateTime.compare(observed, finished) != :lt and
      DateTime.diff(observed, finished) <= @max_bracket_gap_seconds
  end

  defp comparable?(before, after_reading) do
    a = windows(before)
    b = windows(after_reading)
    version = numeric_version(extension(before, "capacity:cli_version"))
    after_time = observed_at(after_reading)

    bucket(before) == bucket(after_reading) and version != nil and
      version == numeric_version(extension(after_reading, "capacity:cli_version")) and
      before.payload["capacity_state"] == "observed" and
      after_reading.payload["capacity_state"] == "observed" and
      before.payload["source"]["event"] == "explicit_read" and
      after_reading.payload["source"]["event"] == "explicit_read" and
      map_size(a) > 0 and Enum.sort(Map.keys(a)) == Enum.sort(Map.keys(b)) and
      Enum.all?(a, fn {kind, w} ->
        other = b[kind]

        w["state"] == "observed" and other["state"] == "observed" and
          is_number(w["used_percent"]) and is_number(other["used_percent"]) and
          w["reset_at"] != nil and w["reset_at"] == other["reset_at"] and
          after_time != nil and compare_iso(w["reset_at"], after_time) == :gt and
          other["used_percent"] >= w["used_percent"]
      end)
  end

  # Window labels are provider-controlled: expose ordinals and durations only.
  defp changes(before, after_reading) do
    after_windows = windows(after_reading)

    windows(before)
    |> Enum.sort()
    |> Enum.with_index(1)
    |> Enum.map(fn {{kind, w}, index} ->
      %{
        "window" => index,
        "window_minutes" => window_minutes(before, kind),
        "observed_change" => after_windows[kind]["used_percent"] - w["used_percent"]
      }
    end)
  end

  defp window_minutes(event, kind) do
    case extension(event, "codex:#{kind}_window_minutes") do
      minutes when is_integer(minutes) and minutes > 0 -> minutes
      _ -> nil
    end
  end

  defp missing_class?(row),
    do:
      Enum.any?(
        ~w(provider harness model effort adapter_version cli_version task_class),
        &(not is_binary(row[&1]) or row[&1] in ["", "unknown"])
      )

  # -- Cross-row checks -------------------------------------------------------

  # Any other run of the provider requested before the after reading and not
  # finished before the before reading overlaps, in any goal.
  defp overlaps(pairs) do
    Enum.map(pairs, fn {row, facts} ->
      count =
        case {observed_at(facts.before), observed_at(facts.after)} do
          {%DateTime{} = left, %DateTime{} = right} ->
            Enum.count(pairs, fn {other, _} ->
              finished = datetime(other["finished_at"])

              other["run_id"] != row["run_id"] and other["provider"] == row["provider"] and
                DateTime.compare(datetime(other["requested_at"]), right) != :gt and
                (is_nil(finished) or DateTime.compare(finished, left) != :lt)
            end)

          _ ->
            row["overlapping_run_count"]
        end

      {Map.put(row, "overlapping_run_count", count), facts}
    end)
  end

  # Inside one attested window nothing else may use the account, so the
  # reading after one run must equal the reading before the next. Any
  # difference is usage the attestation did not account for, and the whole
  # window loses its examples.
  defp contaminate(pairs, windows) do
    contaminated =
      windows
      |> Enum.map(& &1.window_id)
      |> Enum.filter(fn id ->
        pairs
        |> Enum.filter(fn {_row, f} ->
          f.window && f.window.window_id == id && f.before && f.after
        end)
        |> Enum.sort_by(fn {_row, f} ->
          {DateTime.to_unix(observed_at(f.before), :microsecond), f.before.id}
        end)
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.any?(fn [{_, a}, {_, b}] -> changed_between?(a.after, b.before) end)
      end)
      |> MapSet.new()

    Enum.map(pairs, fn {row, facts} ->
      {row,
       Map.put(
         facts,
         :contaminated?,
         facts.window && MapSet.member?(contaminated, facts.window.window_id)
       )}
    end)
  end

  defp changed_between?(earlier, later) do
    a = windows(earlier)
    b = windows(later)

    Enum.any?(a, fn {kind, w} ->
      other = b[kind]

      other != nil and w["reset_at"] == other["reset_at"] and
        w["used_percent"] != other["used_percent"]
    end)
  end

  defp finalize({row, facts}, split_at) do
    capacity =
      capacity(row, facts)
      |> then(fn c ->
        shortest = shortest(c["observed_change_percent"])

        reasons =
          c["exclusion_reasons"]
          |> add(facts[:contaminated?] == true, "collection_window_unexplained_usage")
          |> add(row["overlapping_run_count"] > 0, "concurrent_shoestring_runs")
          |> add(
            c["observed_change_percent"] != nil and is_nil(shortest),
            "window_duration_unknown"
          )
          |> Enum.uniq()
          |> Enum.sort()

        assignable = reasons == []

        Map.merge(c, %{
          "exclusion_reasons" => reasons,
          "assignable" => assignable,
          "attribution_confidence" => if(assignable, do: "high", else: "none"),
          "external_usage" => if(assignable, do: "isolated", else: "unknown"),
          "consumption_percent" => if(assignable, do: shortest["observed_change"]),
          "consumption_window_minutes" => if(assignable, do: shortest["window_minutes"])
        })
      end)

    refs = merge_refs(row["source_events"], facts.refs)

    available_at =
      [row["available_at"] | Enum.map(facts.refs, &ref_time/1)]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&datetime/1)
      |> Enum.max(DateTime)

    row
    |> Map.merge(%{
      "capacity" => capacity,
      "training_eligible" => capacity["assignable"] and row["finished_at"] != nil,
      "available_at" => DateTime.to_iso8601(available_at),
      "split" => split(row, available_at, split_at),
      "source_events" => refs
    })
  end

  # A consumption scalar needs every window's duration; the shortest window is
  # the one a single run moves most.
  defp shortest(nil), do: nil

  defp shortest(changes) do
    if Enum.all?(changes, &is_integer(&1["window_minutes"])),
      do: Enum.min_by(changes, & &1["window_minutes"]),
      else: nil
  end

  defp split(%{"finished_at" => nil}, _available, _split_at), do: "unfinished"
  defp split(_row, _available, nil), do: "unsplit"

  defp split(_row, available, split_at),
    do: if(DateTime.compare(available, split_at) == :lt, do: "train", else: "evaluation")

  defp merge_refs(existing, refs) do
    (existing ++ Enum.map(refs, &reference/1))
    |> Enum.uniq_by(& &1["event_id"])
    |> Enum.sort_by(&{&1["goal_id"], &1["sequence"]})
  end

  defp ref_time(event), do: DateTime.to_iso8601(event.occurred_at)

  defp reference(event),
    do: %{
      "event_id" => event.id,
      "goal_id" => event.goal_id,
      "sequence" => event.sequence,
      "type" => event.type,
      "schema_version" => event.schema_version
    }

  # -- Quality ----------------------------------------------------------------

  defp quality(rows, windows) do
    classes =
      rows
      |> Enum.filter(&(&1["training_eligible"] == true))
      |> Enum.group_by(&Map.take(&1, Shoestring.Forecast.Shadow.class_fields()))
      |> Enum.map(fn {class, members} ->
        %{
          "class_ref" => Dataset.digest(class),
          "train" => Enum.count(members, &(&1["split"] == "train")),
          "evaluation" => Enum.count(members, &(&1["split"] == "evaluation"))
        }
      end)
      |> Enum.sort_by(& &1["class_ref"])

    %{
      "run_count" => length(rows),
      "bracketed_rows" =>
        Enum.count(rows, &(&1["capacity"]["before"] != nil and &1["capacity"]["after"] != nil)),
      "assignable_consumption_rows" => Enum.count(rows, &(&1["capacity"]["assignable"] == true)),
      "training_eligible_rows" => Enum.count(rows, &(&1["training_eligible"] == true)),
      "classes" => classes,
      "forecast_training_ready" =>
        Enum.any?(classes, &(&1["train"] >= 100 and &1["evaluation"] >= 100)),
      "collection_windows" => length(windows),
      "windows_with_unexplained_usage" =>
        rows
        |> Enum.filter(
          &("collection_window_unexplained_usage" in &1["capacity"]["exclusion_reasons"])
        )
        |> Enum.map(& &1["capacity"]["collection_window_id"])
        |> Enum.uniq()
        |> length(),
      "shadow_data_requirements" => %{
        "minimum_training_rows_per_class" => 100,
        "minimum_later_evaluation_rows_per_class" => 100,
        "required_attribution" => "attested_window_bracketed_explicit_reads",
        "required_class_features" => Shoestring.Forecast.Shadow.class_fields(),
        "maximum_bracket_gap_seconds" => @max_bracket_gap_seconds,
        "enforcement_enabled" => false
      },
      "exclusions" =>
        rows |> Enum.flat_map(& &1["capacity"]["exclusion_reasons"]) |> Enum.frequencies(),
      "missingness" =>
        Map.new(
          ~w(model effort adapter_version cli_version task_class),
          fn field -> {field, Enum.count(rows, &is_nil(&1[field]))} end
        )
    }
  end

  defp window_view(window),
    do: %{
      "window_id" => window.window_id,
      "provider" => window.provider,
      "scope_ref" => Dataset.digest(%{"scope" => window.scope}),
      "opened_at" => window.opened_at && DateTime.to_iso8601(window.opened_at),
      "closed_at" => window.closed_at && DateTime.to_iso8601(window.closed_at),
      "close_reason" => window.close_reason
    }

  # -- Helpers ----------------------------------------------------------------

  defp observation(nil), do: nil

  defp observation(event) do
    p = event.payload

    %{
      "event_id" => event.id,
      "observed_at" => p["observed_at"],
      "scope_ref" => Dataset.digest(%{"scope" => p["scope"]}),
      "state" => p["capacity_state"],
      "source_event" => p["source"]["event"],
      "cli_version" => numeric_version(extension(event, "capacity:cli_version"))
    }
  end

  defp windows(event), do: Map.new(event.payload["windows"]["items"] || [], &{&1["kind"], &1})

  defp bucket(event),
    do:
      {event.payload["source"]["provider_id"], event.payload["source"]["adapter_id"],
       event.payload["source"]["invocation_mode"], event.payload["scope"]}

  defp extension(nil, _key), do: nil
  defp extension(event, key), do: get_in(event.payload, ["extensions", key])

  defp observed_at(nil), do: nil
  defp observed_at(event), do: datetime(event.payload["observed_at"])

  defp add(reasons, true, reason), do: [reason | reasons]
  defp add(reasons, _condition, _reason), do: reasons

  defp text(value) when is_binary(value) and value != "",
    do: if(Regex.match?(~r/\A[A-Za-z0-9_.:-]{1,100}\z/, value), do: value, else: nil)

  defp text(_), do: nil

  defp numeric_version(value) when is_binary(value),
    do: if(Regex.match?(~r/\A\d{1,4}(?:\.\d{1,4}){0,3}\z/, value), do: value, else: nil)

  defp numeric_version(_), do: nil

  defp compare_iso(value, %DateTime{} = time) do
    case datetime(value) do
      nil -> nil
      parsed -> DateTime.compare(parsed, time)
    end
  end

  defp datetime(%DateTime{} = time), do: time

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} -> time
      _ -> nil
    end
  end

  defp datetime(_), do: nil
end
