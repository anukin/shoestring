defmodule Shoestring.Advice do
  @moduledoc """
  What past runs of each kind looked like (iteration 14 package I, decision
  6): plain counts, medians and percentiles over finished runs, with no model
  call and no training. Advice is shown to the coordinator and the person; it
  never changes admission, dispatch or checks.

  A kind is the harness, model, effort, purpose and task class (the sorted
  gate names its task cites). A kind with fewer than #{10} finished runs has
  no estimate yet, only its count. With enough runs it reports, over its
  most recent runs:

    * tokens — the median and 90th percentile of what the harness reported
      (Codex's running total, opencode's completion usage, Claude's result
      usage including cache reads and writes); runs that reported none are
      counted separately, never as zero;
    * the first-try pass rate — attempts numbered 1 whose task was accepted;
    * mean attempts per task, and the median run duration;
    * the usage share — the median and 90th percentile of the share of its
      provider's shortest usage window a run used, per window length — over
      the runs iteration 10's measurement dataset can attribute
      (`Shoestring.Measurement.DatasetV2`): Codex runs bracketed by readings
      inside a window the person attested, with nothing else moving the
      reading. Other runs are counted separately, never as zero.

  The usage share is built from the measurement dataset over the goals that
  hold a bracket reading and the Observatory goal, not the whole store, so
  its runs are also checked against every run, EXPLORE or REVIEW call and
  plan review (iteration 8) of the provider in any goal: one that overlapped
  the bracket excludes the run. A plan review records no per-call times, so
  its whole life counts.
  Usage by the coordinator itself (a Codex coordinator during a measured
  Codex run) is not recorded and cannot be told apart; the window's
  attestation has to cover it. Past the dataset's event limit the share is
  reported unavailable, with the reason.

  Advice reads only these canonical events — run requests, starts and ends,
  task dispatches and acceptances, token-bearing harness events and the
  measurement dataset's inputs — never prompts, paths or transcripts.
  """
  import Ecto.Query

  alias Shoestring.Cobbler.PlanRevisionRecord
  alias Shoestring.Cobbler.Review.Record
  alias Shoestring.Dispatches.{Call, Dispatch}
  alias Shoestring.Harness.Observatory
  alias Shoestring.Measurement.{Dataset, DatasetV2}
  alias Shoestring.Repo
  alias Shoestring.Trajectory.TrajectoryEvent

  @min_runs 10
  @recent 200
  @terminal ~w(run.completed run.failed run.interrupted run.cancelled)
  @binding "shoestring.agent:binding"
  @open_reviews ~w(pending held running)
  @types [
    "run.requested",
    "run.running",
    "cobbler.plan.task.dispatched",
    "cobbler.plan.task.accepted" | @terminal
  ]

  def min_runs, do: @min_runs

  @doc "Advice for every kind with at least one finished run, most runs first."
  def report(repo \\ Repo) do
    events =
      repo.all(
        from e in TrajectoryEvent,
          where: e.type in ^@types,
          select: %{
            type: e.type,
            goal_id: e.goal_id,
            payload: e.payload,
            occurred_at: e.occurred_at
          }
      )

    revisions = fn goal_id, number ->
      case repo.get_by(PlanRevisionRecord, goal_id: goal_id, revision_number: number) do
        %PlanRevisionRecord{content: content} -> content
        nil -> nil
      end
    end

    build(
      events,
      token_payloads(repo),
      Map.new(repo.all(from d in Dispatch, select: {d.goal_id, d.purpose})),
      revisions,
      usage_shares(repo)
    )
  end

  @doc "Advice for one kind, or nil when it has no finished run."
  def for_kind(kind, repo \\ Repo), do: Enum.find(report(repo), &(&1["kind"] == kind))

  @doc """
  Advice from canonical events: `events` (maps with `:type`, `:goal_id`,
  `:payload`, `:occurred_at`), the token-bearing harness event payloads,
  `purposes` (goal id to dispatch purpose), `revisions.(goal_id, number)`
  returning plan content and `usage` (`usage_shares/1`'s result).
  """
  def build(events, token_payloads, purposes, revisions, usage \\ {:ok, %{}}) do
    tokens = tokens(token_payloads)

    {shares, unavailable} =
      case usage do
        {:ok, shares} -> {shares, nil}
        {:error, reason} -> {%{}, to_string(reason)}
      end

    events
    |> rows(tokens, shares, purposes, revisions)
    |> Enum.group_by(& &1.kind)
    |> Enum.map(fn {kind, rows} -> summarize(kind, rows, unavailable) end)
    |> Enum.sort_by(&{-&1["runs"], inspect(&1["kind"])})
  end

  # -- Rows ---------------------------------------------------------------

  defp rows(events, tokens, shares, purposes, revisions) do
    by_run = Enum.group_by(events, & &1.payload["run_id"])

    for {run_id, run_events} <- by_run,
        request = Enum.find(run_events, &(&1.type == "run.requested")),
        ended = Enum.find(run_events, &(&1.type in @terminal)),
        dispatched = Enum.find(run_events, &(&1.type == "cobbler.plan.task.dispatched")),
        binding = get_in(request.payload, ["extensions", @binding]),
        is_map(binding) do
      started = Enum.find(run_events, &(&1.type == "run.running"))

      %{
        kind: %{
          "harness" => binding["provider"],
          "model" => binding["model"],
          "effort" => binding["effort"],
          "purpose" => Map.get(purposes, request.goal_id, "implement"),
          "task_class" => task_class(revisions, request.goal_id, dispatched.payload)
        },
        goal_id: request.goal_id,
        task_id: dispatched.payload["plan_task_id"],
        attempt: dispatched.payload["attempt"],
        accepted?: Enum.any?(events, &accepted?(&1, request.goal_id, dispatched.payload)),
        finished_at: ended.occurred_at,
        duration_ms:
          started && DateTime.diff(ended.occurred_at, started.occurred_at, :millisecond),
        tokens: Map.get(tokens, run_id),
        usage: Map.get(shares, run_id)
      }
    end
  end

  defp accepted?(%{type: "cobbler.plan.task.accepted", goal_id: goal_id, payload: p}, goal_id, d),
    do:
      p["plan_task_id"] == d["plan_task_id"] and p["attempt"] == d["attempt"] and
        p["execution_id"] == d["execution_id"]

  defp accepted?(_event, _goal_id, _dispatched), do: false

  defp task_class(revisions, goal_id, dispatched) do
    with number when is_integer(number) <- dispatched["revision_number"],
         %{} = content <- revisions.(goal_id, number),
         %{} = task <-
           Enum.find(content["tasks"] || [], &(&1["id"] == dispatched["plan_task_id"])) do
      "gates:" <>
        (task["gates"] |> Enum.map(& &1["gate"]) |> Enum.uniq() |> Enum.sort() |> Enum.join(","))
    else
      _ -> "unknown"
    end
  end

  @doc false
  def token_payloads(repo) do
    repo.all(
      from e in TrajectoryEvent,
        where:
          e.type == "harness.event_recorded" and
            (fragment("json_extract(?, '$.kind')", e.payload) == "result" or
               fragment("json_extract(?, '$.extensions.\"codex-app-server:method\"')", e.payload) ==
                 "thread/tokenUsage/updated"),
        order_by: [e.goal_id, e.sequence],
        select: e.payload
    )
  end

  # The tokens each run's harness reported: Codex's last running total,
  # otherwise the completion's usage.
  defp tokens(payloads) do
    Enum.reduce(payloads, %{}, fn payload, acc ->
      case count(payload["extensions"] || %{}) do
        nil -> acc
        {:running_total, total} -> Map.put(acc, payload["run_id"], total)
        {:completion, total} -> Map.put_new(acc, payload["run_id"], total)
      end
    end)
  end

  defp count(%{
         "codex-app-server:method" => "thread/tokenUsage/updated",
         "codex-app-server:token_usage" => usage
       }) do
    total = usage["total"] || %{}

    case {total["totalTokens"], total["inputTokens"], total["outputTokens"]} do
      {n, _, _} when is_integer(n) -> {:running_total, n}
      {_, i, o} when is_integer(i) and is_integer(o) -> {:running_total, i + o}
      _ -> nil
    end
  end

  defp count(extensions) do
    parts =
      for {key, value} <- extensions,
          is_integer(value),
          String.ends_with?(
            key,
            ~w(:input_tokens :output_tokens :cache_read_input_tokens :cache_creation_input_tokens)
          ),
          do: {key, value}

    if Enum.any?(parts, fn {key, _} -> String.ends_with?(key, ":output_tokens") end),
      do: {:completion, parts |> Enum.map(&elem(&1, 1)) |> Enum.sum()},
      else: nil
  end

  # -- Usage share ----------------------------------------------------------

  @doc """
  The share of its provider's shortest usage window each attributable run
  used: `{:ok, %{run_id => %{"percent", "window_minutes"}}}`, or
  `{:error, reason}` when the measurement dataset cannot be built (past its
  event limit, for one).
  """
  def usage_shares(repo \\ Repo) do
    goals =
      repo.all(
        from e in TrajectoryEvent,
          where:
            e.type == "capacity.snapshot_observed" and
              like(e.idempotency_key, "measurement-before:%"),
          distinct: true,
          select: e.goal_id
      )

    if goals == [] do
      {:ok, %{}}
    else
      goals = Enum.uniq([Observatory.observatory_goal_id() | goals])

      history =
        repo.all(
          from e in TrajectoryEvent,
            where: e.goal_id in ^goals,
            order_by: [e.goal_id, e.sequence],
            limit: ^(Dataset.max_events() + 1)
        )

      with {:ok, dataset} <- DatasetV2.build(history) do
        spans = spans(repo)

        {:ok,
         for row <- dataset["rows"],
             capacity = row["capacity"],
             capacity["assignable"] == true,
             alone?(row, spans),
             into: %{} do
           {row["run_id"],
            %{
              "percent" => capacity["consumption_percent"],
              "window_minutes" => capacity["consumption_window_minutes"]
            }}
         end}
      end
    end
  end

  # Every run, every EXPLORE or REVIEW call that started and every plan
  # review that made a call, in any goal: `{id, provider, from, to}`, with
  # `to` nil while it has not finished.
  defp spans(repo) do
    runs =
      repo.all(
        from e in TrajectoryEvent,
          where: e.type in ^["run.requested" | @terminal],
          select: %{type: e.type, payload: e.payload, occurred_at: e.occurred_at}
      )
      |> Enum.group_by(& &1.payload["run_id"])
      |> Enum.flat_map(fn {run_id, events} ->
        case Enum.find(events, &(&1.type == "run.requested")) do
          nil ->
            []

          request ->
            ended = Enum.find(events, &(&1.type in @terminal))
            binding = get_in(request.payload, ["extensions", @binding]) || %{}

            providers =
              Enum.reject(
                [Dataset.provider(request.payload["provider_id"]), binding["provider"]],
                &is_nil/1
              )

            for provider <- Enum.uniq(providers),
                do: {run_id, provider, request.occurred_at, ended && ended.occurred_at}
        end
      end)

    calls =
      repo.all(
        from c in Call,
          join: d in Dispatch,
          on: d.id == c.dispatch_id,
          where: not is_nil(c.started_at),
          select: {c.id, d.provider, c.started_at, c.finished_at}
      )

    # A plan review records no per-call times: its whole life counts.
    reviews =
      repo.all(
        from r in Record,
          where: r.calls > 0,
          select: {r.id, r.configuration, r.state, r.inserted_at, r.updated_at}
      )
      |> Enum.map(fn {id, configuration, state, created, updated} ->
        {id, configuration["provider_id"], created,
         if(state in @open_reviews, do: nil, else: updated)}
      end)

    runs ++ calls ++ reviews
  end

  # No other run or call of the provider overlapped the run's readings —
  # the dataset's own rule, applied to the whole store.
  defp alone?(row, spans) do
    {:ok, from, _} = DateTime.from_iso8601(row["capacity"]["before"]["observed_at"])
    {:ok, to, _} = DateTime.from_iso8601(row["capacity"]["after"]["observed_at"])

    not Enum.any?(spans, fn {id, provider, started, finished} ->
      id != row["run_id"] and provider == row["provider"] and
        DateTime.compare(started, to) != :gt and
        (is_nil(finished) or DateTime.compare(finished, from) != :lt)
    end)
  end

  # -- Statistics -----------------------------------------------------------

  defp summarize(kind, rows, usage_unavailable) do
    rows = rows |> Enum.sort_by(& &1.finished_at, {:desc, DateTime}) |> Enum.take(@recent)
    n = length(rows)
    times = Enum.map(rows, & &1.finished_at)

    base = %{
      "kind" => kind,
      "runs" => n,
      "from" => Enum.min(times, DateTime),
      "to" => Enum.max(times, DateTime)
    }

    if n < @min_runs do
      Map.merge(base, %{
        "estimate" => nil,
        "note" => "no estimate yet (#{n} of #{@min_runs} runs)"
      })
    else
      tokens = rows |> Enum.map(& &1.tokens) |> Enum.reject(&is_nil/1)
      measured = rows |> Enum.map(& &1.usage) |> Enum.reject(&is_nil/1)
      first = Enum.filter(rows, &(&1.attempt == 1))
      durations = rows |> Enum.map(& &1.duration_ms) |> Enum.reject(&is_nil/1)

      attempts =
        rows
        |> Enum.group_by(&{&1.goal_id, &1.task_id})
        |> Enum.map(fn {_task, task_rows} ->
          task_rows |> Enum.map(& &1.attempt) |> Enum.max()
        end)

      base
      |> Map.put("estimate", %{
        "tokens" =>
          if(tokens == [],
            do: nil,
            else: %{
              "median" => median(tokens),
              "p90" => percentile(tokens, 90),
              "runs" => length(tokens)
            }
          ),
        "runs_without_tokens" => n - length(tokens),
        "first_try_pass_rate" => %{
          "passed" => Enum.count(first, & &1.accepted?),
          "of" => length(first)
        },
        "mean_attempts" => Float.round(Enum.sum(attempts) / length(attempts), 2),
        "median_duration_ms" => if(durations == [], do: nil, else: median(durations)),
        "usage_share" => usage_share(measured),
        "runs_without_usage_share" => n - length(measured)
      })
      |> then(fn advice ->
        if usage_unavailable,
          do: put_in(advice, ["estimate", "usage_share_unavailable"], usage_unavailable),
          else: advice
      end)
    end
  end

  # Shares of windows of different lengths are never pooled.
  defp usage_share([]), do: nil

  defp usage_share(measured) do
    measured
    |> Enum.group_by(& &1["window_minutes"], & &1["percent"])
    |> Enum.sort()
    |> Enum.map(fn {minutes, percents} ->
      %{
        "window_minutes" => minutes,
        "median_percent" => median(percents),
        "p90_percent" => percentile(percents, 90),
        "runs" => length(percents)
      }
    end)
  end

  @doc false
  def median(values), do: percentile(values, 50)

  # Nearest rank: the smallest value with at least `p` percent at or below it.
  @doc false
  def percentile(values, p) do
    sorted = Enum.sort(values)
    Enum.at(sorted, max(ceil(p / 100 * length(sorted)) - 1, 0))
  end
end
