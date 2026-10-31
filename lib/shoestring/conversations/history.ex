defmodule Shoestring.Conversations.History do
  @moduledoc """
  A conversation rebuilt from its trajectory events, with no model call: the
  visible messages in order, each turn and what it delivered, the inbox, and
  the provider session to resume. The engine keeps one as its state and
  clients render one, so both read the same facts.

  A human message or inbox entry is *pending* until a turn delivers it. A
  turn is *open* from `conversation.turn.requested` until its
  `conversation.turn.ended`; at most one is open. `hold` is the latest
  `conversation.turn.held` (why pending input is not being delivered) until
  the next turn is requested.

  A handoff (`Shoestring.Conversations.Handoff`) is `handoff` here: its id
  (the successor conversation's), whether a note was asked for, and its
  status (`:requested`, `:prepared`, `:done`). In the successor, the received
  handoff is a pending message of kind `:handoff`, the person's carried
  messages are pending `:human` ones, and `known` holds the inbox entries the
  predecessor delivered, so they are not announced again.
  """

  alias Shoestring.Conversations.Handoff
  alias Shoestring.Trajectory.TrajectoryEvent

  defstruct messages: [],
            visible_bytes: 0,
            turns: %{},
            turn_order: [],
            inbox: [],
            delivered: MapSet.new(),
            open_turn: nil,
            hold: nil,
            provider_session_id: nil,
            handoff: nil,
            predecessor_id: nil,
            known: [],
            last_sequence: 0

  @type t :: %__MODULE__{}

  @statuses %{
    "completed" => :completed,
    "interrupted" => :interrupted,
    "failed" => :failed,
    "uncertain" => :uncertain,
    "unsent" => :unsent
  }

  # Dispatch states after which a dispatch changes no more.
  @final ~w(completed cancelled failed failed_to_start)

  @doc "The history of `events`, in sequence order."
  @spec from_events([TrajectoryEvent.t()]) :: t()
  def from_events(events), do: Enum.reduce(events, %__MODULE__{}, &apply_event(&2, &1))

  @doc "`history` with one more committed event."
  @spec apply_event(t(), TrajectoryEvent.t()) :: t()
  def apply_event(history, %TrajectoryEvent{} = event) do
    history
    |> fold(event.type, event.payload, event)
    |> Map.put(:last_sequence, max(history.last_sequence, event.sequence))
  end

  defp fold(history, "conversation.message.human", payload, event) do
    message = %{
      kind: :human,
      id: payload["message_id"],
      text: payload["text"],
      turn_id: nil,
      at: event.occurred_at
    }

    %{
      history
      | messages: history.messages ++ [message],
        visible_bytes: history.visible_bytes + byte_size(message.text)
    }
  end

  defp fold(history, "conversation.message.coordinator", payload, event) do
    message = %{
      kind: :coordinator,
      id: "#{payload["turn_id"]}:#{payload["item"]}",
      text: payload["text"],
      turn_id: payload["turn_id"],
      at: event.occurred_at
    }

    %{
      history
      | messages: history.messages ++ [message],
        visible_bytes: history.visible_bytes + byte_size(message.text)
    }
  end

  defp fold(history, "conversation.turn.requested", payload, event) do
    turn = %{
      id: payload["turn_id"],
      status: :open,
      message_ids: payload["message_ids"],
      inbox_ids: payload["inbox_ids"],
      grant_id: payload["grant_id"],
      admission: payload["admission"],
      tools: [],
      reason: nil,
      usage: %{},
      requested_at: event.occurred_at,
      ended_at: nil
    }

    %{
      history
      | turns: Map.put(history.turns, turn.id, turn),
        turn_order: history.turn_order ++ [turn.id],
        delivered:
          MapSet.union(history.delivered, MapSet.new(turn.message_ids ++ turn.inbox_ids)),
        open_turn: turn.id,
        hold: nil
    }
  end

  defp fold(history, "conversation.turn.ended", payload, event) do
    history
    |> update_turn(payload["turn_id"], fn turn ->
      %{
        turn
        | status: Map.fetch!(@statuses, payload["status"]),
          reason: payload["reason"],
          usage: payload["usage"] || %{},
          ended_at: event.occurred_at
      }
    end)
    |> then(fn h ->
      if h.open_turn == payload["turn_id"], do: %{h | open_turn: nil}, else: h
    end)
  end

  defp fold(history, "conversation.tool.called", payload, _event) do
    update_turn(history, payload["turn_id"], fn turn ->
      %{turn | tools: turn.tools ++ [%{call_id: payload["call_id"], tool: payload["tool"]}]}
    end)
  end

  defp fold(history, "conversation.tool.returned", payload, _event) do
    update_turn(history, payload["turn_id"], fn turn ->
      call_id = payload["call_id"]

      tools =
        Enum.map(turn.tools, fn
          %{call_id: ^call_id} = call -> Map.put(call, :is_error, payload["is_error"])
          call -> call
        end)

      %{turn | tools: tools}
    end)
  end

  defp fold(history, "conversation.turn.held", payload, event) do
    hold = %{
      reason: payload["reason"],
      grant_id: payload["grant_id"],
      defer_until: payload["defer_until"],
      at: event.occurred_at
    }

    %{history | hold: hold}
  end

  defp fold(history, "conversation.provider_session.bound", payload, _event),
    do: %{history | provider_session_id: payload["provider_session_id"]}

  defp fold(history, "conversation.inbox.recorded", payload, event) do
    entry = %{
      id: payload["entry_id"],
      dispatch_id: payload["dispatch_id"],
      state: payload["state"],
      purpose: payload["purpose"],
      title: payload["title"],
      worker: payload["worker"],
      settlement_ref: payload["settlement_ref"],
      at: event.occurred_at
    }

    %{history | inbox: history.inbox ++ [entry]}
  end

  defp fold(history, "conversation.handoff.requested", payload, event) do
    history = %{
      history
      | handoff: %{
          id: payload["handoff_id"],
          note: payload["note"],
          status: :requested,
          prepared: nil
        }
    }

    case payload["instruction"] do
      nil -> history
      text -> add_message(history, :handoff_request, payload["handoff_id"], text, event)
    end
  end

  defp fold(history, "conversation.handoff.prepared", payload, _event),
    do: %{history | handoff: %{history.handoff | status: :prepared, prepared: payload}}

  defp fold(history, "conversation.handed_off", _payload, _event),
    do: %{history | handoff: %{history.handoff | status: :done}}

  defp fold(history, "conversation.handoff.received", payload, event) do
    known =
      for entry <- payload["known"] || [] do
        %{
          id: nil,
          dispatch_id: entry["dispatch_id"],
          state: entry["state"],
          settlement_ref: entry["settlement_ref"],
          known: true,
          at: event.occurred_at
        }
      end

    history =
      %{history | predecessor_id: payload["predecessor_id"], known: history.known ++ known}
      |> add_message(:handoff, payload["predecessor_id"], Handoff.text(payload), event)

    Enum.reduce(payload["carried"] || [], history, fn message, history ->
      add_message(history, :human, message["message_id"], message["text"], event)
    end)
  end

  defp fold(history, _type, _payload, _event), do: history

  defp add_message(history, kind, id, text, event) do
    message = %{kind: kind, id: id, text: text, turn_id: nil, at: event.occurred_at}

    %{
      history
      | messages: history.messages ++ [message],
        visible_bytes: history.visible_bytes + byte_size(text)
    }
  end

  defp update_turn(history, turn_id, fun) do
    case history.turns do
      %{^turn_id => turn} -> %{history | turns: Map.put(history.turns, turn_id, fun.(turn))}
      _ -> history
    end
  end

  @doc """
  The human messages, handoff texts and inbox entries no turn has delivered
  yet, oldest first.
  """
  @spec pending(t()) :: %{messages: [map()], inbox: [map()]}
  def pending(history) do
    %{
      messages:
        Enum.filter(
          history.messages,
          &(&1.kind in [:human, :handoff, :handoff_request] and
              not MapSet.member?(history.delivered, &1.id))
        ),
      inbox: Enum.reject(history.inbox, &MapSet.member?(history.delivered, &1.id))
    }
  end

  @doc "Whether an inbox entry is recorded for `dispatch_id` in `state`."
  def recorded?(history, dispatch_id, state, settlement_ref \\ nil),
    do:
      Enum.any?(
        history.inbox ++ history.known,
        &(&1.dispatch_id == dispatch_id and &1.state == state and
            (is_nil(settlement_ref) or Map.get(&1, :settlement_ref) == settlement_ref or
               (is_nil(Map.get(&1, :settlement_ref)) and observed_before?(settlement_ref, &1.at))))
      )

  defp observed_before?(reference, at) do
    case String.split(reference, ":", parts: 2) do
      [since, _digest] ->
        case Integer.parse(since) do
          {value, ""} -> value <= DateTime.to_unix(at, :microsecond)
          _ -> false
        end

      _ ->
        false
    end
  end

  @doc "Whether `dispatch_id` has an inbox entry for a state it never leaves."
  def final?(history, dispatch_id),
    do:
      Enum.any?(
        history.inbox ++ history.known,
        &(&1.dispatch_id == dispatch_id and &1.state in @final)
      )

  @doc "The turns in the order they were requested."
  def turns(history), do: Enum.map(history.turn_order, &Map.fetch!(history.turns, &1))

  @doc "Whether an inbox entry has been delivered by a turn."
  def delivered?(history, id), do: MapSet.member?(history.delivered, id)
end
