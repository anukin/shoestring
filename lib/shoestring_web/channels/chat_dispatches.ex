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
      for key <-
            ~w(state worker reviewer waiting attempts_used duration_ms next result reviews report),
          value = data[key],
          not is_nil(value),
          do: key <> ": " <> render(value)

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

  defp render(value) when is_binary(value), do: value
  defp render(value), do: Jason.encode!(value)

  defp terminal(run) do
    if TerminalAccess.interactive?(run), do: "/runs/#{run.id}/terminal", else: nil
  end
end
