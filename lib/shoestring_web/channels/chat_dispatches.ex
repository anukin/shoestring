defmodule ShoestringWeb.ChatDispatches do
  @moduledoc "Read-only dispatch presentation for native chat; never advances execution."
  alias Shoestring.Dispatches
  alias Shoestring.CLI.Commands.Runs
  alias ShoestringWeb.TerminalAccess
  @final ~w(completed cancelled failed failed_to_start)

  def rows(session, cache, now) do
    Enum.map_reduce(Dispatches.list(session), cache, fn dispatch, cache ->
      case cache[dispatch.id] do
        %{final: true, row: row} ->
          {row, cache}

        previous ->
          detail = Runs.detail(dispatch)
          after_sequence = if previous, do: previous.cursor, else: 0
          steps = steps(dispatch, after_sequence)

          latest =
            case List.last(steps["entries"]) do
              nil -> previous && previous.row["latest_step"]
              entry -> entry["line"]
            end

          run = Dispatches.latest_run(dispatch)
          final? = detail["state"] in @final

          latest_at =
            case List.last(steps["entries"]) do
              nil -> previous && previous.latest_at
              entry -> entry["at"]
            end

          ended_at = if final?, do: latest_at || dispatch.updated_at, else: now

          row =
            Map.take(detail, ~w(dispatch_id purpose worker reviewer state title next))
            |> Map.merge(%{
              "elapsed_seconds" => max(DateTime.diff(ended_at, dispatch.inserted_at), 0),
              "waiting_until" => get_in(detail, ["waiting", "until"]),
              "latest_step" => latest,
              "run_id" => run && run.id,
              "terminal" => terminal(run)
            })

          {row,
           Map.put(cache, dispatch.id, %{
             row: row,
             cursor: steps["last_sequence"] || 0,
             latest_at: latest_at,
             final: final?
           })}
      end
    end)
  end

  def detail(dispatch) do
    data = Runs.detail(dispatch)

    lines =
      Enum.flat_map(
        ~w(state worker reviewer waiting attempts_used duration_ms next result reviews report),
        &lines(&1, data[&1], data)
      )

    %{
      "dispatch_id" => dispatch.id,
      "lines" => lines,
      "terminal" => terminal(Dispatches.latest_run(dispatch))
    }
  end

  def steps(dispatch, after_sequence) do
    collect_steps(dispatch, after_sequence, [], 0)
  end

  defp collect_steps(dispatch, cursor, kept, count) do
    data = Runs.log(dispatch, cursor)
    entries = kept ++ data["entries"]
    count = count + length(data["entries"])
    kept = Enum.take(entries, -500)
    next = data["last_sequence"]

    if is_integer(next) and next > cursor do
      collect_steps(dispatch, next, kept, count)
    else
      Map.merge(data, %{"entries" => kept, "omitted" => max(count - 500, 0)})
    end
  end

  # The detail as a person reads it: reports, results and review rounds as
  # text, one line per item; a shape not known here is shown as indented JSON.
  defp lines(_key, nil, _data), do: []
  defp lines(_key, [], _data), do: []

  defp lines("waiting", %{"until" => until, "reason" => reason}, _data),
    do: ["waiting: until #{until} (#{reason})"]

  defp lines("result", result, _data) when is_map(result) do
    ["result: commit #{result["commit"]} on #{short_sha(result["base"])}"] ++
      Enum.map(result["checks"] || [], &check/1) ++
      Enum.map(result["diff_stat"] || [], &("  " <> &1)) ++
      ["  To take it:" | Enum.map(result["take"] || [], &("    " <> &1))]
  end

  defp lines("reviews", reviews, _data) when is_list(reviews) do
    ["reviews:" | Enum.flat_map(reviews, &review_round/1)]
  end

  defp lines("report", %{"findings" => _, "open_questions" => _} = report, _data) do
    findings = report["findings"]

    ["report:", "  Summary: #{report["summary"]}"] ++
      ["  Findings (#{length(findings)}, #{report["supported_findings"]} supported):"] ++
      Enum.flat_map(findings, &explore_finding/1) ++
      case report["open_questions"] do
        [] -> []
        questions -> ["  Open questions:" | Enum.map(questions, &("    ? " <> &1))]
      end
  end

  defp lines("report", %{"outcome" => outcome, "findings" => findings} = report, _data) do
    [
      "report: #{outcome} (#{report["blocking_count"] || 0} blocking)",
      "  Summary: #{report["summary"]}"
    ] ++
      Enum.flat_map(findings, &review_finding/1)
  end

  defp lines(key, value, _data) when is_binary(value), do: [key <> ": " <> value]
  defp lines(key, value, _data) when is_number(value), do: [key <> ": #{value}"]

  defp lines(key, value, _data),
    do: [
      key <> ":"
      | value |> Jason.encode!(pretty: true) |> String.split("\n") |> Enum.map(&("  " <> &1))
    ]

  defp check(check) do
    optional = if field(check, :required) == false, do: " (optional)", else: ""

    status =
      if field(check, :exit_status) == 0,
        do: "passed",
        else: "FAILED (exit #{field(check, :exit_status)})"

    last = field(check, :last_line)

    "  check #{argv(field(check, :argv))}: #{status}#{optional}" <>
      if(last, do: " · #{last}", else: "")
  end

  defp review_round(review) do
    reviewer =
      if field(review, :reviewer),
        do: "#{field(review, :reviewer)}:#{field(review, :model)}",
        else: field(review, :unavailable)

    findings = field(review, :findings) || []

    [
      "  round #{field(review, :attempt)} by #{reviewer}: #{field(review, :state)} " <>
        "(#{field(review, :blocking) || 0} blocking, #{length(findings)} total)"
    ] ++ Enum.flat_map(findings, &review_finding/1)
  end

  defp explore_finding(finding) do
    mark = if finding["supported"] == false, do: " (not supported by the copy)", else: ""

    evidence =
      Enum.map_join(finding["evidence"] || [], ", ", fn e ->
        "#{e["path"]}:#{e["line"]}" <> if(e["supported"] == false, do: " ✗", else: "")
      end)

    ["    • #{finding["claim"]}#{mark}", "      #{evidence}"]
  end

  defp review_finding(finding) do
    where =
      case finding do
        %{"path" => path, "line" => line} when is_binary(path) and is_integer(line) ->
          " #{path}:#{line}"

        %{"path" => path} when is_binary(path) ->
          " #{path}"

        _ ->
          ""
      end

    ["    #{finding["id"]} [#{finding["severity"]}]#{where} #{finding["claim"]}"] ++
      if(is_binary(finding["correction"]) and finding["correction"] != "",
        do: ["      fix: #{finding["correction"]}"],
        else: []
      )
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp argv(argv) when is_list(argv), do: Enum.join(argv, " ")
  defp argv(argv), do: to_string(argv)
  defp short_sha(sha) when is_binary(sha), do: String.slice(sha, 0, 12)
  defp short_sha(sha), do: inspect(sha)

  defp terminal(run) do
    if TerminalAccess.interactive?(run), do: "/runs/#{run.id}/terminal", else: nil
  end
end
