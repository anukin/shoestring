defmodule ShoestringWeb.SessionActivity do
  @moduledoc """
  What an agent did, as the Sessions page's feed shows it: one row per
  command, file change, message, ask or Shoestring step, oldest first.

  A worker's rows come from its run's normalized events
  (`harness.event_recorded`), its dispatch log (`runs log`) and its asks. A
  coordinator's rows come from its conversation events: turns, the names of
  the tools it used, and both sides' visible messages. Neither ever has model
  reasoning: the harness normalizers and the conversation events never keep
  it, and every extension map is passed through
  `ShoestringWeb.RunPresentation.sanitize_payload/1` before it is read, so a
  reasoning-shaped key is dropped and secret-shaped text is redacted.

  Read-only: building a feed never changes a record.
  """

  import Ecto.Query

  alias Shoestring.{PermissionAsks, Repo}
  alias Shoestring.Trajectory.TrajectoryEvent
  alias ShoestringWeb.{ChatDispatches, RunPresentation}

  @max_rows 500
  # Normalized events read for one dispatch, newest kept.
  @max_events 4000
  # A message longer than this is clipped on the page until opened.
  @long_message 280

  @file_tools ~w(Edit MultiEdit Write NotebookEdit)

  @doc "Rows kept per feed; earlier ones are counted as omitted."
  def max_rows, do: @max_rows

  @doc "Whether a message row is long enough to be clipped."
  def long?(%{kind: :message, text: text}), do: String.length(text) > @long_message
  def long?(%{kind: :you, text: text}), do: String.length(text) > @long_message
  def long?(_row), do: false

  @doc """
  A worker dispatch's feed: `%{rows: rows, omitted: n}`. `final?` marks the
  last message as the worker's final one when its dispatch is over and the
  provider did not say which message was final.
  """
  def dispatch(dispatch, final? \\ false) do
    steps = ChatDispatches.steps(dispatch, 0)

    step_rows =
      steps["entries"]
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} ->
        row("s-#{entry["sequence"] || index}", entry["at"], :step, entry["line"])
      end)

    rows =
      (step_rows ++ run_rows(dispatch.goal_id) ++ ask_rows(dispatch.id))
      |> Enum.sort_by(&{DateTime.to_unix(&1.at, :microsecond), &1.order})
      |> mark_final(final?)

    cap(rows, steps["omitted"] || 0)
  end

  @doc "A coordinator's feed across the session's conversations: `%{rows: rows, omitted: n}`."
  def coordinator(conversations) do
    ids = Enum.map(conversations, & &1.id)

    events =
      Repo.all(
        from e in TrajectoryEvent,
          where: e.goal_id in ^ids and like(e.type, "conversation.%"),
          order_by: [asc: e.occurred_at, asc: e.sequence]
      )

    {rows, _turns} =
      Enum.flat_map_reduce(events, %{}, fn event, turns ->
        coordinator_rows(event, turns)
      end)

    cap(rows, 0)
  end

  defp cap(rows, omitted) do
    extra = max(length(rows) - @max_rows, 0)
    %{rows: Enum.drop(rows, extra), omitted: omitted + extra}
  end

  # -- A worker's run ----------------------------------------------------------

  defp run_rows(nil), do: []

  defp run_rows(goal_id) do
    events =
      Repo.all(
        from e in TrajectoryEvent,
          where: e.goal_id == ^goal_id and e.type == "harness.event_recorded",
          order_by: [desc: e.sequence],
          limit: @max_events
      )
      |> Enum.reverse()

    root =
      Enum.find_value(events, fn event ->
        ext = extensions(event)
        ext["claude-headless:cwd"] || ext["codex-app-server:cwd"]
      end)

    {rows, _open} =
      Enum.reduce(events, {[], %{}}, fn event, acc -> fold(event, acc, root) end)

    rows
    |> Enum.reverse()
    |> Enum.reject(&(&1.text in [nil, ""]))
  end

  defp extensions(%TrajectoryEvent{payload: payload}),
    do: RunPresentation.sanitize_payload(payload["extensions"] || %{})

  # `open` maps an item's id to the index of its row in `rows` (newest
  # first), so a completed item updates the row its start made.
  defp fold(%TrajectoryEvent{} = event, {rows, open}, root) do
    ext = extensions(event)
    at = event.occurred_at

    case {event.payload["kind"], ext} do
      {"command", %{"codex-app-server:command" => command} = ext} ->
        id = "c-" <> (ext["codex-app-server:item_id"] || "#{event.sequence}")

        row =
          row(id, at, :command, command, event.sequence)
          |> Map.merge(%{
            exit: ext["codex-app-server:exit_code"],
            seconds: seconds(ext["codex-app-server:duration_ms"]),
            running: ext["codex-app-server:status"] == "inProgress"
          })

        upsert(rows, open, id, row, &Map.put(row, :at, &1.at))

      {"command", %{"claude-headless:boundary" => "start"} = ext} ->
        id = "c-" <> (ext["claude-headless:tool_use_id"] || "#{event.sequence}")
        {kind, text} = claude_tool(ext, root)
        row = row(id, at, kind, text, event.sequence) |> Map.put(:running, true)
        upsert(rows, open, id, row, fn _ -> row end)

      {"command", %{"claude-headless:boundary" => "end"} = ext} ->
        id = "c-" <> (ext["claude-headless:tool_use_id"] || "")

        case Map.fetch(open, id) do
          {:ok, _} ->
            upsert(rows, open, id, nil, fn previous ->
              %{
                previous
                | running: false,
                  failed: ext["claude-headless:is_error"] == true,
                  seconds: DateTime.diff(at, previous.at, :millisecond) / 1000
              }
            end)

          :error ->
            {rows, open}
        end

      {"tool", %{"codex-app-server:tool" => "fileChange"} = ext} ->
        id = "f-" <> (ext["codex-app-server:item_id"] || "#{event.sequence}")

        case ext["codex-app-server:changes"] do
          [_ | _] = changes ->
            row = row(id, at, :file, file_changes(changes, root), event.sequence)
            upsert(rows, open, id, row, &Map.put(row, :at, &1.at))

          _ ->
            {rows, open}
        end

      {"output", %{"codex-app-server:text" => text} = ext} ->
        # A completed message: it replaces the pieces streamed before it.
        row =
          row("m-#{event.sequence}", at, :message, text, event.sequence)
          |> Map.put(:final, ext["codex-app-server:phase"] == "final_answer")

        case open do
          %{writing: _} -> upsert(rows, open, :writing, nil, fn _ -> row end) |> close(:writing)
          _ -> {[row | rows], open}
        end

      {"output", %{"codex-app-server:delta" => delta}} ->
        case open do
          %{writing: _} ->
            upsert(rows, open, :writing, nil, &%{&1 | text: &1.text <> delta})

          _ ->
            row = row("m-#{event.sequence}", at, :message, delta, event.sequence)
            {[Map.put(row, :writing, true) | rows], open |> shift() |> Map.put(:writing, 0)}
        end

      {"output", %{"claude-headless:output_text" => text} = ext} ->
        # Text a tool handed back is not the worker speaking.
        if ext["claude-headless:role"] == "user" do
          {rows, open}
        else
          {[row("m-#{event.sequence}", at, :message, text, event.sequence) | rows], shift(open)}
        end

      _ ->
        {rows, open}
    end
  end

  # Inserts `row` as new, or updates the open row `id` with `update`.
  defp upsert(rows, open, id, row, update) do
    case Map.fetch(open, id) do
      {:ok, index} ->
        {List.update_at(rows, index, update), open}

      :error when is_map(row) ->
        {[row | rows], open |> shift() |> Map.put(id, 0)}

      :error ->
        {rows, open}
    end
  end

  defp close({rows, open}, id), do: {rows, Map.delete(open, id)}

  # A row was put in front: every open row moved one place back.
  defp shift(open), do: Map.new(open, fn {id, index} -> {id, index + 1} end)

  defp claude_tool(ext, root) do
    name = ext["claude-headless:tool_name"] || "a tool"
    path = relative(ext["claude-headless:file_path"], root)

    cond do
      ext["claude-headless:command"] -> {:command, ext["claude-headless:command"]}
      name in @file_tools and path -> {:file, "#{name} #{path}"}
      path -> {:tool, "#{name} #{path}"}
      true -> {:tool, name}
    end
  end

  defp file_changes(changes, root) do
    Enum.map_join(changes, ", ", fn change ->
      path = relative(change["path"], root) || "a file"
      {added, removed} = counts(change["diff"])

      case {added, removed} do
        {0, 0} -> "#{path} (#{change["kind"] || "changed"})"
        _ -> "#{path} +#{added} −#{removed}"
      end
    end)
  end

  defp counts(diff) when is_binary(diff) do
    diff
    |> String.split("\n")
    |> Enum.reduce({0, 0}, fn
      "+++" <> _, acc -> acc
      "---" <> _, acc -> acc
      "+" <> _, {a, r} -> {a + 1, r}
      "-" <> _, {a, r} -> {a, r + 1}
      _, acc -> acc
    end)
  end

  defp counts(_diff), do: {0, 0}

  # A worker's own paths are shown from its worktree; anything else is
  # shown as recorded (already redacted).
  defp relative(nil, _root), do: nil
  defp relative(path, nil), do: path

  defp relative(path, root) do
    case Path.relative_to(path, root) do
      ^path -> path
      relative -> relative
    end
  end

  defp seconds(ms) when is_integer(ms), do: ms / 1000
  defp seconds(_ms), do: nil

  defp mark_final(rows, false), do: rows

  defp mark_final(rows, true) do
    if Enum.any?(rows, &(&1.kind == :message and &1.final)) do
      rows
    else
      case Enum.find_index(Enum.reverse(rows), &(&1.kind == :message)) do
        nil ->
          rows

        from_end ->
          List.update_at(rows, length(rows) - 1 - from_end, &%{&1 | final: true})
      end
    end
  end

  # -- Asks --------------------------------------------------------------------

  defp ask_rows(dispatch_id) do
    Repo.all(
      from a in PermissionAsks.Ask,
        where: a.dispatch_id == ^dispatch_id,
        order_by: [a.inserted_at, a.id]
    )
    |> Enum.flat_map(fn ask ->
      asked = row("a-#{ask.id}", ask.inserted_at, :ask, asked(ask))

      case answer(ask) do
        nil -> [Map.put(asked, :waiting, PermissionAsks.waiting?(ask))]
        text -> [asked, row("a-#{ask.id}-answer", ask.decided_at || ask.updated_at, :step, text)]
      end
    end)
  end

  defp asked(%{kind: "network"} = ask), do: "Asked you: #{redact(ask.command)}"

  defp asked(%{kind: "file_change"} = ask),
    do: "Asked you to allow a file change: #{redact(ask.command)}"

  defp asked(ask), do: "Asked you to run outside its sandbox: #{redact(ask.command)}"

  defp answer(%{state: "pending"}), do: nil
  defp answer(%{state: "allowed", decided_by: "rule:" <> _}), do: "Allowed by the agent's rule."
  defp answer(%{state: "allowed", kind: "network"}), do: "You allowed it for this run."
  defp answer(%{state: "allowed"}), do: "You allowed it."

  defp answer(%{state: "denied", note: note}) when is_binary(note) and note != "",
    do: "You denied it: #{redact(note)}"

  defp answer(%{state: "denied"}), do: "You denied it."
  defp answer(%{state: "expired"}), do: "The ask ended without an answer: its run stopped."
  defp answer(%{state: state}), do: "Ask #{state}."

  # -- A coordinator -----------------------------------------------------------

  defp coordinator_rows(%TrajectoryEvent{type: type, payload: p} = e, turns) do
    at = e.occurred_at
    id = "#{e.goal_id}-#{e.sequence}"

    case type do
      "conversation.message.human" ->
        {[row(id, at, :you, redact(p["text"]))], turns}

      "conversation.message.coordinator" ->
        {[row(id, at, :message, redact(p["text"]))], turns}

      "conversation.turn.requested" ->
        n = map_size(turns) + 1
        {[row(id, at, :step, "Turn #{n} began#{delivers(p)}.")], Map.put(turns, p["turn_id"], n)}

      "conversation.turn.ended" ->
        n = Map.get(turns, p["turn_id"])
        {[row(id, at, :step, "Turn #{n || "?"} #{turn_end(p["status"])}.")], turns}

      "conversation.tool.called" ->
        {[row("t-" <> to_string(p["call_id"] || id), at, :tool, to_string(p["tool"]))], turns}

      "conversation.turn.held" ->
        {[row(id, at, :step, "Held before its next turn: #{redact(p["reason"])}.")], turns}

      "conversation.inbox.recorded" ->
        {[row(id, at, :step, inbox(p))], turns}

      "conversation.opened" ->
        {[row(id, at, :step, "Conversation opened.")], turns}

      "conversation.handoff.completed" ->
        {[row(id, at, :step, "Handed off to a new conversation.")], turns}

      _ ->
        {[], turns}
    end
  end

  defp delivers(%{"message_ids" => m, "inbox_ids" => i}) do
    parts =
      [
        count(length(m || []), "message from you", "messages from you"),
        count(length(i || []), "inbox entry", "inbox entries")
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [], do: "", else: ": " <> Enum.join(parts, " and ")
  end

  defp delivers(_payload), do: ""

  defp count(0, _one, _many), do: nil
  defp count(1, one, _many), do: "1 #{one}"
  defp count(n, _one, many), do: "#{n} #{many}"

  defp turn_end("completed"), do: "ended"
  defp turn_end("interrupted"), do: "was interrupted"
  defp turn_end("failed"), do: "failed"
  defp turn_end("uncertain"), do: "ended without its end being seen"
  defp turn_end("unsent"), do: "was never sent"
  defp turn_end(other), do: "ended (#{other})"

  defp inbox(p) do
    id = String.slice(to_string(p["dispatch_id"]), 0, 8)

    "Inbox: #{String.upcase(to_string(p["purpose"]))} #{id} #{p["state"]}" <>
      if(p["title"], do: ": #{redact(p["title"])}", else: "")
  end

  # -- Rows ----------------------------------------------------------------------

  defp row(id, at, kind, text, order \\ 0) do
    %{
      id: to_string(id),
      at: at,
      order: order,
      kind: kind,
      text: if(is_binary(text), do: redact(text), else: text),
      exit: nil,
      seconds: nil,
      running: false,
      failed: false,
      final: false,
      writing: false,
      waiting: false
    }
  end

  defp redact(nil), do: ""
  defp redact(text), do: RunPresentation.redact_text(to_string(text))
end
