defmodule Shoestring.Conversations.Handoff do
  @moduledoc """
  Continuing a session in a fresh conversation (iteration 16 package A),
  only when the person asks (`/handoff`).

  The session, its grant and its dispatches stay as they are; only the
  coordinator's context starts again. What carries over has two halves:

    * **Facts**, written here from Shoestring's records and never by a model:
      the grant's remaining room, and each dispatch of the session with its
      state, commit and the commands to take it, review rounds and next step.
    * **The note**, the old coordinator's judgement (intent, decisions and
      why, open questions), written in one charged turn that delivers only
      `instruction/0`. It is at most `max_note_bytes/0`; a longer note, a
      turn that did not complete, or a handoff asked for without one carries
      the facts alone and says why.

  Human messages the old coordinator never received are carried over as
  pending, and so is every inbox entry it was not given. The new
  conversation's first turn delivers the handoff text with the person's next
  message; the handoff itself starts no turn there.
  """

  alias Shoestring.{Dispatches, Grants}
  alias Shoestring.CLI.Commands.Runs
  alias Shoestring.Conversations.{Conversation, History}
  alias Shoestring.Trajectory.Redaction

  @max_note_bytes 16_384
  @max_facts_bytes 24_576
  # Room past the conversation's text bound for the handoff turn: its
  # instruction and the note it asks for.
  @headroom 65_536

  def max_note_bytes, do: @max_note_bytes
  def max_facts_bytes, do: @max_facts_bytes
  def headroom, do: @headroom

  @doc "What the handoff turn delivers to the old coordinator."
  def instruction do
    """
    Shoestring is handing this conversation off: the person asked to continue \
    this session in a fresh coordinator conversation, with the same grant and \
    dispatches. Do not call tools or dispatch anything in this turn.

    Reply with only the handoff note your successor reads first. Shoestring \
    adds the facts itself (every dispatch's state, commits, review rounds and \
    the grant's remaining room), so do not repeat them. Write:
    - what the person wants, in their words where it matters;
    - decisions made and why, and requirements they stated;
    - open questions, what you were waiting for, and what you told them you \
    would do next;
    - anything you were told not to do, and conflicts you are holding.

    Keep it under #{div(@max_note_bytes, 1024)} KiB; a longer note is not carried over.\
    """
  end

  @doc """
  The handoff turn's note and why it is or is not carried: `{note, status}`,
  `status` one of `written`, `not_requested`, `skipped[:hold reason]`,
  `empty`, `too_large` or `turn_<status>`.
  """
  def note(%History{} = history, handoff) do
    turn =
      Enum.find(History.turns(history), &(handoff.id in &1.message_ids))

    cond do
      not handoff.note ->
        {nil, "not_requested"}

      # Asked again without a note while the note turn was held.
      turn == nil ->
        {nil, if(history.hold, do: "skipped:#{history.hold.reason}", else: "skipped")}

      turn.status != :completed ->
        {nil, "turn_#{turn.status}"}

      true ->
        text =
          history.messages
          |> Enum.filter(&(&1.kind == :coordinator and &1.turn_id == turn.id))
          |> Enum.map_join("\n\n", & &1.text)
          |> String.trim()

        cond do
          text == "" -> {nil, "empty"}
          byte_size(text) > @max_note_bytes -> {nil, "too_large"}
          true -> {text, "written"}
        end
    end
  end

  @doc """
  The `conversation.handoff.prepared` payload for handing `conversation` off
  to `successor_id`, from its history and Shoestring's records now.
  """
  def prepare(%Conversation{} = conversation, %History{} = history, successor_id, now) do
    {note, status} = note(history, history.handoff)
    pending = History.pending(history)

    %{
      "successor_id" => successor_id,
      "facts" => facts(conversation, history, now),
      "note_status" => status,
      "carried" =>
        for(
          message <- pending.messages,
          message.kind == :human,
          do: %{"message_id" => message.id, "text" => message.text}
        ),
      # Inbox entries the coordinator was given: the successor does not
      # announce them again. Any other is announced to it.
      "known" =>
        for(
          entry <- history.inbox ++ history.known,
          History.delivered?(history, entry.id) or Map.get(entry, :known, false),
          do: %{
            "dispatch_id" => entry.dispatch_id,
            "state" => entry.state,
            "settlement_ref" => entry.settlement_ref
          }
        )
    }
    |> then(&if(note, do: Map.put(&1, "note", note), else: &1))
  end

  @doc """
  The facts half: Shoestring's records only, at most `max_facts_bytes/0`.
  Older dispatches past the bound are counted, never cut mid-line.
  """
  def facts(%Conversation{} = conversation, %History{} = history, now) do
    head = [
      "Facts from Shoestring's records (not written by a model), at #{DateTime.to_iso8601(now)}:",
      "- Session #{conversation.session_id} in #{conversation.repository_root}; coordinator " <>
        "#{conversation.provider}:#{conversation.model}.",
      "- The previous conversation took #{length(history.turn_order)} turns and holds " <>
        "#{history.visible_bytes} bytes of visible text.",
      grant_line(Grants.active(conversation.session_id))
    ]

    dispatches = Dispatches.list(conversation.session_id) |> Enum.reverse()
    lines = Enum.map(dispatches, &dispatch_line/1)
    budget = @max_facts_bytes - byte_size(Enum.join(head, "\n")) - 200

    {kept, _bytes} =
      Enum.reduce_while(lines, {[], 0}, fn line, {kept, bytes} ->
        if bytes + byte_size(line) + 1 <= budget,
          do: {:cont, {[line | kept], bytes + byte_size(line) + 1}},
          else: {:halt, {kept, bytes}}
      end)

    kept = Enum.reverse(kept)
    omitted = length(lines) - length(kept)

    section =
      case dispatches do
        [] ->
          ["- No dispatches yet."]

        _ ->
          ["Dispatches in this session, newest first (#{length(dispatches)}):" | kept] ++
            if omitted > 0,
              do: ["- #{omitted} older dispatches not listed here; runs_list shows them."],
              else: []
      end

    Enum.join(head ++ section, "\n")
  end

  defp grant_line(nil), do: "- The session has no active grant."

  defp grant_line(grant) do
    room = Dispatches.room(grant)
    left = fn %{"used" => used, "limit" => limit} -> "#{max(limit - used, 0)} of #{limit}" end

    "- Grant #{short(grant.id)}: #{left.(%{"used" => grant.turns_used, "limit" => grant.max_turns})} " <>
      "coordinator turns left; #{left.(room["attempts"])} dispatch attempts left; " <>
      "#{room["running"]["now"]} running of #{room["running"]["limit"]} at once; " <>
      "#{left.(room["seconds"])} seconds left; #{left.(room["unread_usage"])} unread-usage " <>
      "pre-approvals left; models #{Enum.join(grant.models, ", ")}; purposes " <>
      "#{Enum.join(grant.purposes, ", ")}."
  end

  defp dispatch_line(dispatch) do
    detail = Runs.detail(dispatch)

    parts =
      [
        "- #{dispatch.id} #{dispatch.purpose} \"#{Redaction.redact(dispatch.title)}\" on " <>
          "#{detail["worker"]}: #{detail["state"]}",
        detail["of"] && "review of #{detail["of"]}",
        result(detail["result"]),
        reviews(detail["reviews"]),
        detail["next"] && "next: #{detail["next"]}"
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, "; ") <> "."
  end

  defp result(nil), do: nil

  defp result(result) do
    checks =
      case result["checks"] do
        [_ | _] = checks ->
          failed = Enum.count(checks, &(&1[:exit_status] != 0))
          ", #{length(checks)} checks (#{failed} failed)"

        _ ->
          ""
      end

    "commit #{result["commit"]} on #{result["base"]}#{checks}; take: " <>
      Enum.join(result["take"] || [], " && ")
  end

  defp reviews(nil), do: nil
  defp reviews([]), do: nil

  defp reviews(reviews) do
    last = List.last(reviews)

    "#{length(reviews)} review rounds, last #{last[:state]} with #{last[:blocking]} blocking findings"
  end

  @doc """
  What the successor's first turn delivers: the received payload as text,
  facts first, then the note or why there is none.
  """
  def text(payload) do
    note =
      case payload do
        %{"note" => note} ->
          "The previous coordinator's note (its judgement; check it against the facts):\n\n" <>
            note

        %{"note_status" => status} ->
          "The previous coordinator wrote no note (#{status}); rely on the facts and ask " <>
            "the person what matters."
      end

    """
    This conversation continues coordinator conversation #{payload["predecessor_id"]} in the \
    same session, with the same grant and dispatches; the person asked for a handoff. \
    runs_show and read_inbox give anything below in detail.

    #{payload["facts"]}

    #{note}\
    """
  end

  defp short(id), do: String.slice(id, 0, 8)
end
