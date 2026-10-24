defmodule Shoestring.Measurement.Dataset do
  @moduledoc """
  Rebuildable v1 measurements from canonical history, never provider transcripts.

  Capacity changes are account observations, not run consumption. Historical
  events do not establish the absence of external usage, so v1 deliberately
  exports no assignable consumption labels and cannot enable learned routing.
  """
  alias Shoestring.Cobbler.PlanContract
  alias Shoestring.Harness.CapacitySnapshot
  alias Shoestring.Trajectory.EventRegistry

  @version 1
  @max_events 10_000
  @terminal ~w(run.completed run.failed run.interrupted run.cancelled)
  @adapters %{
    "claude_headless_stream_json" => "claude",
    "codex_app_server_stdio" => "codex",
    "opencode_acp" => "opencode",
    "claude_interactive_pty" => "claude",
    "codex_interactive_pty" => "codex",
    "fixture_interactive_pty" => "fixture",
    "shoestring.harness.fake" => "fake"
  }

  def version, do: @version
  def max_events, do: @max_events
  def encode(dataset), do: PlanContract.canonical_json(dataset) <> "\n"

  def digest(value),
    do: :crypto.hash(:sha256, PlanContract.canonical_json(value)) |> Base.encode16(case: :lower)

  @doc "Build from a consistent, complete event snapshot. No wall clock or mutable projections."
  def build(events, opts \\ []) when is_list(events) do
    with :ok <- validate_history(events),
         {:ok, split_at} <- split_at(opts) do
      events = Enum.sort_by(events, &{&1.goal_id, &1.sequence})
      requests = Enum.filter(events, &(&1.type == "run.requested"))

      if duplicate_runs?(requests) do
        {:error, :duplicate_run_identity}
      else
        snapshots = snapshots(events)
        by_run = Enum.group_by(events, &{&1.goal_id, run_id(&1)})
        rows = Enum.map(requests, &row(&1, by_run, requests, snapshots, split_at))

        {:ok,
         %{
           "dataset_version" => @version,
           "extractor_version" => @version,
           "split_at" => iso(split_at),
           "source_digest" => source_digest(events),
           "source_event_count" => length(events),
           "source_watermarks" => watermarks(events),
           "rows" => rows,
           "quality" => quality(rows, snapshots)
         }}
      end
    end
  end

  defp validate_history(events) when length(events) > @max_events,
    do: {:error, :measurement_event_limit}

  defp validate_history(events) do
    registered = MapSet.new(EventRegistry.registered_types())

    cond do
      Enum.any?(events, &(not MapSet.member?(registered, {&1.type, &1.schema_version}))) ->
        {:error, :unsupported_history}

      length(Enum.uniq_by(events, & &1.id)) != length(events) ->
        {:error, :duplicate_event_identity}

      Enum.any?(Enum.group_by(events, & &1.goal_id), fn {_goal, history} ->
        Enum.sort(Enum.map(history, & &1.sequence)) != Enum.to_list(1..length(history))
      end) ->
        {:error, :history_sequence_gap}

      true ->
        validate_payloads(events)
    end
  end

  defp validate_payloads(events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      attrs =
        Map.take(
          event,
          ~w(id goal_id task_id run_id sequence parent_event_id type actor occurred_at schema_version payload idempotency_key)a
        )

      case EventRegistry.validate(attrs) do
        {:ok, _} -> {:cont, :ok}
        # Never include a changeset, payload, actor or arbitrary error text in output.
        {:error, _} -> {:halt, {:error, :invalid_history}}
      end
    end)
  end

  defp duplicate_runs?(requests),
    do: length(Enum.uniq_by(requests, & &1.payload["run_id"])) != length(requests)

  defp row(request, by_run, requests, snapshots, split_at) do
    run_id = request.payload["run_id"]
    owned = Map.get(by_run, {request.goal_id, run_id}, [])
    started = Enum.find(owned, &(&1.type == "run.running"))
    ended = Enum.find(owned, &(&1.type in @terminal))
    lease = Enum.find(owned, &(&1.type == "lease.proposed"))
    adapter = request.payload["provider_id"]
    provider = @adapters[adapter]

    before =
      lease &&
        Enum.find(
          snapshots,
          &(&1.payload["snapshot_id"] == lease.payload["admitted_snapshot_id"] and
              &1.goal_id == request.goal_id and provider != nil and
              &1.payload["source"]["provider_id"] == provider)
        )

    after_reading = after_reading(before, ended, snapshots)
    overlapping = overlaps(request, before, after_reading, requests, by_run, provider)
    capacity = capacity(before, after_reading, started, ended, overlapping)
    accepted = Enum.find(owned, &(&1.type == "cobbler.plan.task.accepted"))
    attempt = Enum.find(owned, &(&1.type == "cobbler.plan.task.dispatched"))
    gates = Enum.filter(owned, &(&1.type == "cobbler.plan.gate.completed"))
    refs = Enum.uniq_by(owned ++ Enum.reject([before, after_reading], &is_nil/1), & &1.id)
    available_at = refs |> Enum.map(& &1.occurred_at) |> Enum.max(DateTime)

    %{
      "run_id" => run_id,
      "goal_id" => request.goal_id,
      "task_id" => request.task_id,
      "provider" => provider || "unknown",
      "harness" => if(provider, do: adapter, else: "unknown"),
      "model" => nil,
      "effort" => nil,
      "adapter_version" => nil,
      "cli_version" =>
        before && numeric_version(before.payload["extensions"]["capacity:cli_version"]),
      "task_class" => "unknown",
      "repository_language" => nil,
      "repository_size_bucket" => nil,
      "context_size_bucket" => nil,
      "requested_at" => iso(request.occurred_at),
      "started_at" => started && iso(started.occurred_at),
      "finished_at" => ended && iso(ended.occurred_at),
      "available_at" => iso(available_at),
      "duration_ms" => duration(started, ended),
      "result" =>
        if(ended, do: String.replace_prefix(ended.type, "run.", ""), else: "unfinished"),
      "verified_outcome" => if(accepted, do: "task_accepted", else: "unverified"),
      "attempt" => attempt && nonnegative_integer(attempt.payload["attempt"]),
      "lease" => lease_features(lease),
      "gates" => Enum.map(gates, &gate_features/1),
      "checkpoint_count" => Enum.count(owned, &(&1.type == "checkpoint.created")),
      "handoff_count" => Enum.count(owned, &(&1.type == "handoff.created")),
      "handoff_tax_ms" => nil,
      "concurrent_reservation_units" => nil,
      "overlapping_run_count" => overlapping,
      "capacity" => capacity,
      "training_eligible" => false,
      "split" => split(ended, available_at, split_at),
      "source_events" =>
        refs |> Enum.sort_by(&{&1.goal_id, &1.sequence}) |> Enum.map(&reference/1)
    }
  end

  defp snapshots(events),
    do: Enum.filter(events, &(&1.type == "capacity.snapshot_observed" and &1.schema_version == 2))

  defp after_reading(nil, _, _), do: nil
  defp after_reading(_, nil, _), do: nil

  defp after_reading(before, ended, snapshots) do
    snapshots
    |> Enum.filter(fn event ->
      event.payload["snapshot_id"] != before.payload["snapshot_id"] and
        bucket(event) == bucket(before) and
        compare_datetime(event.payload["observed_at"], ended.occurred_at) in [:eq, :gt] and
        DateTime.compare(event.occurred_at, ended.occurred_at) in [:eq, :gt]
    end)
    |> Enum.sort_by(&{&1.payload["observed_at"], &1.goal_id, &1.sequence})
    |> List.first()
  end

  defp bucket(event),
    do:
      {event.payload["source"]["provider_id"], event.payload["source"]["adapter_id"],
       event.payload["source"]["invocation_mode"], event.payload["scope"]}

  defp capacity(before, after_reading, started, ended, overlapping) do
    reasons = ["external_usage_unknown"]
    reasons = if is_nil(before), do: ["missing_before_observation" | reasons], else: reasons
    reasons = if is_nil(after_reading), do: ["missing_after_observation" | reasons], else: reasons

    reasons =
      if is_nil(started) or is_nil(ended),
        do: ["incomplete_run_boundaries" | reasons],
        else: reasons

    reasons =
      if started && ended && is_nil(duration(started, ended)),
        do: ["inconsistent_run_timestamps" | reasons],
        else: reasons

    reasons = if overlapping > 0, do: ["concurrent_shoestring_runs" | reasons], else: reasons

    reasons =
      if before && started && not fresh?(before, started.occurred_at),
        do: ["before_observation_not_fresh" | reasons],
        else: reasons

    reasons =
      if after_reading && ended && not near_after?(after_reading, ended.occurred_at),
        do: ["after_observation_too_late" | reasons],
        else: reasons

    comparable = before && after_reading && windows_comparable?(before, after_reading)

    reasons =
      if before && after_reading && not comparable,
        do: ["incomparable_windows_or_versions" | reasons],
        else: reasons

    %{
      "before" => observation(before),
      "after" => observation(after_reading),
      "observed_change_percent" =>
        if(comparable, do: window_changes(before, after_reading), else: nil),
      "consumption_percent" => nil,
      "assignable" => false,
      "attribution_confidence" => "none",
      "external_usage" => "unknown",
      "exclusion_reasons" => Enum.sort(reasons)
    }
  end

  defp observation(nil), do: nil

  defp observation(event) do
    p = event.payload

    %{
      "event_id" => event.id,
      "observed_at" => p["observed_at"],
      "expires_at" => p["expires_at"],
      "scope_ref" => digest(%{"scope" => p["scope"]}),
      "state" => p["capacity_state"],
      "confidence" => p["confidence"],
      "support_tier" => p["support_tier"],
      "compatibility" => p["compatibility_state"],
      "freshness_max_age_seconds" => p["freshness"]["max_age_seconds"],
      "cli_version" => numeric_version(p["extensions"]["capacity:cli_version"])
    }
  end

  defp windows_comparable?(before, after_reading) do
    a = windows(before)
    b = windows(after_reading)
    version = numeric_version(before.payload["extensions"]["capacity:cli_version"])

    bucket(before) == bucket(after_reading) and version != nil and
      version == numeric_version(after_reading.payload["extensions"]["capacity:cli_version"]) and
      before.payload["capacity_state"] == "observed" and
      after_reading.payload["capacity_state"] == "observed" and
      Enum.sort(Map.keys(a)) == Enum.sort(Map.keys(b)) and map_size(a) > 0 and
      Enum.all?(a, fn {kind, w} ->
        other = b[kind]

        w["state"] == "observed" and other["state"] == "observed" and
          w["reset_at"] != nil and w["reset_at"] == other["reset_at"] and
          compare_datetime(w["reset_at"], datetime(after_reading.payload["observed_at"])) == :gt and
          other["used_percent"] >= w["used_percent"]
      end)
  end

  defp windows(event), do: Map.new(event.payload["windows"]["items"], &{&1["kind"], &1})

  defp window_changes(before, after_reading) do
    after_windows = windows(after_reading)
    # Window names are provider-controlled labels: expose only an ordinal.
    windows(before)
    |> Enum.sort()
    |> Enum.with_index(1)
    |> Enum.map(fn {{kind, w}, index} ->
      %{
        "window" => index,
        "observed_change" => after_windows[kind]["used_percent"] - w["used_percent"]
      }
    end)
  end

  defp fresh?(event, time) do
    case CapacitySnapshot.from_payload(event.payload, now: event.occurred_at) do
      {:ok, snapshot} -> CapacitySnapshot.eligible?(snapshot, time)
      _ -> false
    end
  end

  defp near_after?(event, time) do
    observed = datetime(event.payload["observed_at"])

    observed && fresh?(event, observed) &&
      DateTime.diff(observed, time) <= event.payload["freshness"]["max_age_seconds"]
  end

  defp overlaps(_request, nil, _, _requests, _events, _provider), do: 0
  defp overlaps(_request, _, nil, _requests, _events, _provider), do: 0

  defp overlaps(request, before, after_reading, requests, by_run, provider) do
    left = datetime(before.payload["observed_at"])
    right = datetime(after_reading.payload["observed_at"])

    if left && right do
      Enum.count(requests, fn other ->
        owned = Map.get(by_run, {other.goal_id, other.payload["run_id"]}, [])

        ended = Enum.find(owned, &(&1.type in @terminal))

        other.id != request.id and @adapters[other.payload["provider_id"]] == provider and
          DateTime.compare(other.occurred_at, right) != :gt and
          (is_nil(ended) or DateTime.compare(ended.occurred_at, left) != :lt)
      end)
    else
      0
    end
  end

  defp lease_features(nil), do: nil

  defp lease_features(event) do
    p = event.payload

    %{
      "response_budget" => nonnegative_integer(p["response_budget"]),
      "tool_budget" => nonnegative_integer(p["tool_budget"]),
      "response_reserve" => nonnegative_integer(p["reserves"]["response"]),
      "tool_reserve" => nonnegative_integer(p["reserves"]["tool"]),
      "deadline" => p["deadline"],
      "checkpoint_cadence" => nonnegative_integer(p["checkpoint_cadence"])
    }
  end

  defp gate_features(event) do
    p = event.payload

    %{
      "kind" =>
        if(p["kind"] in ~w(status lint typecheck test build), do: p["kind"], else: "other"),
      "required" => p["required"] == true,
      "result" =>
        if(p["result"] in ~w(passed failed timed_out cancelled error skipped),
          do: p["result"],
          else: "other"
        ),
      "duration_ms" => nonnegative_integer(p["duration_ms"])
    }
  end

  defp quality(rows, snapshots) do
    %{
      "run_count" => length(rows),
      "snapshot_count" => length(snapshots),
      "finished_runs" => Enum.count(rows, &(&1["finished_at"] != nil)),
      "verified_tasks" => Enum.count(rows, &(&1["verified_outcome"] == "task_accepted")),
      "assignable_consumption_rows" => 0,
      "forecast_training_ready" => false,
      "shadow_data_requirements" => %{
        "minimum_training_rows_per_class" => 100,
        "minimum_later_evaluation_rows_per_class" => 100,
        "required_attribution" => "independently_established_isolation",
        "required_class_features" =>
          ~w(provider harness model effort adapter_version cli_version task_class),
        "enforcement_enabled" => false
      },
      "exclusions" =>
        rows |> Enum.flat_map(& &1["capacity"]["exclusion_reasons"]) |> Enum.frequencies(),
      "missingness" =>
        Map.new(
          ~w(model effort adapter_version cli_version repository_language repository_size_bucket context_size_bucket handoff_tax_ms concurrent_reservation_units),
          fn field -> {field, Enum.count(rows, &is_nil(&1[field]))} end
        )
    }
  end

  defp watermarks(events),
    do:
      events
      |> Enum.group_by(& &1.goal_id)
      |> Enum.map(fn {goal, history} ->
        last = List.last(history)

        %{
          "goal_id" => goal,
          "sequence" => last.sequence,
          "event_id" => last.id,
          "occurred_at" => iso(last.occurred_at)
        }
      end)
      |> Enum.sort_by(& &1["goal_id"])

  defp source_digest(events),
    do:
      events
      |> Enum.map(fn event ->
        reference(event)
        |> Map.put("occurred_at", iso(event.occurred_at))
        |> Map.put("payload", event.payload)
      end)
      |> then(&digest(%{"events" => &1}))

  defp reference(event),
    do: %{
      "event_id" => event.id,
      "goal_id" => event.goal_id,
      "sequence" => event.sequence,
      "type" => event.type,
      "schema_version" => event.schema_version
    }

  defp run_id(event), do: event.run_id || event.payload["run_id"]
  defp duration(nil, _), do: nil
  defp duration(_, nil), do: nil

  defp duration(started, ended) do
    elapsed = DateTime.diff(ended.occurred_at, started.occurred_at, :millisecond)
    if elapsed >= 0, do: elapsed, else: nil
  end

  defp datetime(nil), do: nil

  defp datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} -> time
      _ -> nil
    end
  end

  defp compare_datetime(_, nil), do: nil

  defp compare_datetime(value, time) do
    case datetime(value) do
      nil -> nil
      parsed -> DateTime.compare(parsed, time)
    end
  end

  defp iso(nil), do: nil
  defp iso(time), do: DateTime.to_iso8601(time)

  defp numeric_version(value) when is_binary(value),
    do: if(Regex.match?(~r/\A\d{1,4}(?:\.\d{1,4}){0,3}\z/, value), do: value, else: nil)

  defp numeric_version(_), do: nil
  defp nonnegative_integer(value) when is_integer(value) and value >= 0, do: value
  defp nonnegative_integer(_), do: nil
  defp split(nil, _, _), do: "unfinished"
  defp split(_, _, nil), do: "unsplit"

  defp split(_ended, available_at, time),
    do: if(DateTime.compare(available_at, time) == :lt, do: "train", else: "evaluation")

  defp split_at(opts) do
    case Keyword.get(opts, :split_at) do
      nil -> {:ok, nil}
      %DateTime{} = time -> {:ok, time}
      _ -> {:error, :invalid_split_timestamp}
    end
  end
end
