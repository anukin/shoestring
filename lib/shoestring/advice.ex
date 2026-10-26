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
    * mean attempts per task, and the median run duration.

  Usage per run as a share of a provider's window is not reported yet: it
  needs the readings around runs that ran alone, which iteration 10's
  measurement dataset attributes (`mix shoestring.measurements`).

  Advice reads only these canonical events — run requests, starts and ends,
  task dispatches and acceptances, and token-bearing harness events — never
  prompts, paths or transcripts.
  """
  import Ecto.Query

  alias Shoestring.Cobbler.PlanRevisionRecord
  alias Shoestring.Dispatches.Dispatch
  alias Shoestring.Repo
  alias Shoestring.Trajectory.TrajectoryEvent

  @min_runs 10
  @recent 200
  @terminal ~w(run.completed run.failed run.interrupted run.cancelled)
  @binding "shoestring.agent:binding"
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
      revisions
    )
  end

  @doc "Advice for one kind, or nil when it has no finished run."
  def for_kind(kind, repo \\ Repo), do: Enum.find(report(repo), &(&1["kind"] == kind))

  @doc """
  Advice from canonical events: `events` (maps with `:type`, `:goal_id`,
  `:payload`, `:occurred_at`), the token-bearing harness event payloads,
  `purposes` (goal id to dispatch purpose) and `revisions.(goal_id, number)`
  returning plan content.
  """
  def build(events, token_payloads, purposes, revisions) do
    tokens = tokens(token_payloads)

    events
    |> rows(tokens, purposes, revisions)
    |> Enum.group_by(& &1.kind)
    |> Enum.map(fn {kind, rows} -> summarize(kind, rows) end)
    |> Enum.sort_by(&{-&1["runs"], inspect(&1["kind"])})
  end

  # -- Rows ---------------------------------------------------------------

  defp rows(events, tokens, purposes, revisions) do
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
        tokens: Map.get(tokens, run_id)
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

  # -- Statistics -----------------------------------------------------------

  defp summarize(kind, rows) do
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
      first = Enum.filter(rows, &(&1.attempt == 1))
      durations = rows |> Enum.map(& &1.duration_ms) |> Enum.reject(&is_nil/1)

      attempts =
        rows
        |> Enum.group_by(&{&1.goal_id, &1.task_id})
        |> Enum.map(fn {_task, task_rows} ->
          task_rows |> Enum.map(& &1.attempt) |> Enum.max()
        end)

      Map.put(base, "estimate", %{
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
        "median_duration_ms" => if(durations == [], do: nil, else: median(durations))
      })
    end
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
