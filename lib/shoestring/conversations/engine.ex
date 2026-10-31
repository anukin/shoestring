defmodule Shoestring.Conversations.Engine do
  @moduledoc """
  One coordinator conversation's process (iteration 15 package C).

  It holds the person's messages and the session's inbox and starts a turn
  only while the coordinator is idle: Phase 0 found the coordinator CLIs
  disagree about a message sent mid-turn, so nothing is ever sent during
  one. A turn delivers every pending message and inbox entry at once.

  Every fact is a trajectory event before it is acted on
  (`Shoestring.Conversations.Events`), and the engine's state is the
  `Shoestring.Conversations.History` of those events:

    * A turn's intent (`conversation.turn.requested`, naming what it
      delivers) is recorded before the turn is handed to the coordinator.
    * A turn whose end was never seen — the service restarted, or the
      coordinator process stopped mid-turn — ends `uncertain`. One that was
      never handed over ends `unsent`. Neither is sent again: what it
      delivered is not pending any more, so nothing retries a model call.
    * Visible text is stored redacted (`Shoestring.Trajectory.Redaction`),
      and the coordinator is sent the redacted message, so the stored
      conversation is what the coordinator saw.
    * An oversized message is refused before it is recorded. Replies are
      assembled in memory until a message boundary, tool call or turn end,
      then redacted and recorded, so chunk boundaries cannot expose secrets.
      The cumulative turn output is bounded; an oversized reply interrupts
      the turn and ends `failed` with `reply_too_large`.

  **Grant and admission** (package D). A turn needs the session's active
  grant, admission and one of the grant's turns, in that order, before its
  intent is recorded:

    * Admission treats the turn as a `read_only` call of the coordinator's
      provider on its subscription, against the standing reserves. The
      grant's turns are the person's attributable confirmation (decided with
      the user on 2026-10-28), so unread usage does not hold a granted turn;
      a breached reserve defers it, with no other model or provider.
    * The turn is charged (`Shoestring.Grants.use_turn/2`) once, before it
      is handed over. A turn that ends `unsent` is refunded; one that may
      have reached the coordinator stays charged.
    * Without a grant, turns or admission, the input stays pending and a
      `conversation.turn.held` records why, once per reason. Each poll tries
      again, so extending the grant or a reset of the reserve releases it.
      Nothing running is interrupted.

  **Inbox.** Every `poll_ms` (default 2 s) the engine reads the session's
  dispatches as `shoestring wait` does: it confirms holds the grant
  pre-approved (`Shoestring.Dispatches.advance/1`) and records an inbox entry
  once for each distinct decision or review in a settled state. The poll never
  interrupts a turn; entries wait for the coordinator to be idle.

  **Handoff** (iteration 16 package A, `Shoestring.Conversations.Handoff`).
  Asked for only by the person (`handoff/2`), and refused while a turn is
  open. With a note, one turn delivers only the handoff instruction, may use
  `Handoff.headroom/0` past the text bound (so a conversation at its limit
  can still hand off), and is charged and admitted like any turn; no other
  turn starts in this conversation after the request. Then
  `conversation.handoff.prepared` records what carries over and
  `Shoestring.Conversations.hand_off/2` switches the session to the
  successor in one transaction; this engine starts the successor's and
  stops. A held note turn can be skipped by asking again without a note.
  Messages the person sends meanwhile are carried over; after `prepared`
  they are refused (`handoff_in_progress`).

  **Restart.** A new engine rebuilds its history from events without a
  model call and starts no turn by itself; a handoff under way continues
  where it stopped. The coordinator process is
  started at the first turn, resuming the provider session recorded in
  `conversation.provider_session.bound`.

  Options: `:conversation_module` (default: the provider's `:converse`
  module), `:conversation_opts`, `:instructions` (default: the file
  `Shoestring.Conversations.instructions_path/1` names), `:tools_url` (default the
  endpoint's `/mcp`; nil for no tools), `:poll_ms` (nil turns the timer off;
  `poll/1` still works), `:max_reply_bytes` (256 KiB per turn),
  `:max_input_bytes` (128 KiB of queued human input and per delivered turn),
  `:max_context_bytes` (4 MiB of retained visible message text),
  `:start_successor` (default true: start the successor's engine after a
  handoff). Context
  exhaustion refuses explicitly; provider tokens and tool-result context are
  owned by the provider CLI and are not estimated from this byte bound.
  """

  use GenServer, restart: :transient

  require Logger

  alias Shoestring.{Authority, Conversations, Dispatches, Grants, Harnesses, Trajectory}
  alias Shoestring.Cobbler.{AdmissionEvaluation, WakeupObserve}
  alias Shoestring.Conversations.{Conversation, Events, Handoff, History}
  alias Shoestring.Coordinator.ToolTokens
  alias Shoestring.Harness.{ConversationEvent, Error}
  alias Shoestring.Trajectory.Redaction

  @max_message_bytes 32_768
  @max_reply_bytes 262_144
  @max_input_bytes 131_072
  @max_context_bytes 4_194_304
  @poll_ms 2_000
  @scope "subscription"

  def max_message_bytes, do: @max_message_bytes

  def start_link({%Conversation{} = conversation, opts}),
    do: GenServer.start_link(__MODULE__, {conversation, opts}, name: via(conversation.id))

  def child_spec({%Conversation{id: id}, _opts} = arg),
    do: %{id: {__MODULE__, id}, start: {__MODULE__, :start_link, [arg]}, restart: :transient}

  @doc "The registered name of a conversation's engine."
  def via(conversation_id),
    do: {:via, Registry, {Shoestring.Conversations.Registry, conversation_id}}

  @doc """
  Records the person's message `message_id` (a UUID the client chooses, so
  a resend records nothing twice) and starts a turn if the coordinator is
  idle.
  """
  def say(engine, message_id, text), do: GenServer.call(engine, {:say, message_id, text})

  @doc """
  Hands the conversation off to a fresh one in the same session.
  `note: true` asks the coordinator for its note first (one turn); `false`
  carries the facts alone, and also skips a note turn that is held.
  `{:error, :turn_running}` while a turn is open.
  """
  def handoff(engine, opts \\ []),
    do: GenServer.call(engine, {:handoff, Keyword.get(opts, :note, true)}, 30_000)

  @doc "Interrupts the running turn; `{:error, :no_turn}` when none runs."
  def cancel_turn(engine), do: GenServer.call(engine, :cancel_turn)

  def status(engine), do: GenServer.call(engine, :status)
  def history(engine), do: GenServer.call(engine, :history)

  @doc "Reads the session's dispatches now, as the timer does."
  def poll(engine), do: GenServer.call(engine, :poll, 30_000)

  # -- Server ----------------------------------------------------------------

  @impl GenServer
  def init({conversation, opts}) do
    Process.flag(:trap_exit, true)

    with {:ok, module} <- conversation_module(conversation, opts),
         {:ok, events} <- Trajectory.replay(conversation.id),
         history = History.from_events(events),
         :ok <-
           if(match?(%{status: :done}, history.handoff), do: {:error, :handed_off}, else: :ok) do
      state = %{
        conversation: conversation,
        history: history,
        module: module,
        opts: opts,
        adapter: nil,
        token: nil,
        turn: nil,
        poll_ms: Keyword.get(opts, :poll_ms, @poll_ms),
        max_reply_bytes: Keyword.get(opts, :max_reply_bytes, @max_reply_bytes),
        max_input_bytes: Keyword.get(opts, :max_input_bytes, @max_input_bytes),
        max_context_bytes: Keyword.get(opts, :max_context_bytes, @max_context_bytes)
      }

      state =
        case state.history.open_turn do
          nil -> state
          turn_id -> end_turn(state, turn_id, "uncertain", "service_restarted")
        end

      if state.history.handoff, do: send(self(), :advance_handoff)
      schedule_poll(state)
      {:ok, state}
    end
  end

  defp conversation_module(conversation, opts) do
    case Keyword.fetch(opts, :conversation_module) do
      {:ok, module} ->
        {:ok, module}

      :error ->
        case Harnesses.module(conversation.provider, :converse) do
          {:ok, module} -> {:ok, module}
          :error -> {:error, {:cannot_converse, conversation.provider}}
        end
    end
  end

  @impl GenServer
  def handle_call({:say, message_id, text}, _from, state) when is_binary(text) do
    raw_bytes = byte_size(text)
    known? = Enum.any?(state.history.messages, &(&1.kind == :human and &1.id == message_id))
    text = Redaction.redact(text)
    pending = History.pending(state.history)
    pending_bytes = byte_size(turn_text(%{pending | inbox: []}))
    separator_bytes = if pending.messages == [], do: 0, else: 2

    cond do
      match?(%{status: status} when status != :requested, state.history.handoff) ->
        {:reply, {:error, :handoff_in_progress}, state}

      max(raw_bytes, byte_size(text)) > min(@max_message_bytes, state.max_input_bytes) ->
        {:reply, {:error, :message_too_large}, state}

      String.trim(text) == "" ->
        {:reply, {:error, :empty_message}, state}

      not known? and state.history.visible_bytes + byte_size(text) > state.max_context_bytes ->
        {:reply, {:error, :context_limit_reached}, state}

      not known? and pending_bytes + byte_size(text) + separator_bytes > state.max_input_bytes ->
        {:reply, {:error, :pending_input_too_large}, state}

      true ->
        payload = %{"message_id" => message_id, "text" => text}

        case record(
               state,
               "conversation.message.human",
               payload,
               "message:#{message_id}",
               "human"
             ) do
          {:ok, state} -> {:reply, :ok, maybe_start_turn(state)}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:handoff, note}, _from, state) do
    cond do
      state.turn != nil or state.history.open_turn != nil ->
        {:reply, {:error, :turn_running}, state}

      state.history.handoff == nil ->
        id = Ecto.UUID.generate()

        payload =
          %{"handoff_id" => id, "note" => note}
          |> then(&if(note, do: Map.put(&1, "instruction", Handoff.instruction()), else: &1))

        case record(
               state,
               "conversation.handoff.requested",
               payload,
               "handoff-requested",
               "human"
             ) do
          {:ok, state} -> {:reply, :ok, maybe_start_turn(state)}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      # The note turn is held (no turns left, a reserve): carry the facts alone.
      state.history.handoff.status == :requested and not note ->
        {:reply, :ok, prepare_handoff(state)}

      true ->
        {:reply, {:error, :handoff_in_progress}, state}
    end
  end

  def handle_call(:cancel_turn, _from, %{turn: nil} = state),
    do: {:reply, {:error, :no_turn}, state}

  def handle_call(:cancel_turn, _from, state) do
    :ok = state.module.cancel_turn(state.adapter)
    {:reply, :ok, state}
  end

  def handle_call(:status, _from, state) do
    pending = History.pending(state.history)

    {:reply,
     %{
       state: if(state.turn, do: :in_turn, else: :idle),
       turn_id: state.turn && state.turn.id,
       pending_messages: length(pending.messages),
       pending_inbox: length(pending.inbox),
       provider_session_id: state.history.provider_session_id,
       hold: state.history.hold && state.history.hold.reason,
       context_bytes: state.history.visible_bytes,
       context_limit: state.max_context_bytes,
       handoff: state.history.handoff && state.history.handoff.status
     }, state}
  end

  def handle_call(:history, _from, state), do: {:reply, state.history, state}
  def handle_call(:poll, _from, state), do: {:reply, :ok, check_dispatches(state)}

  @impl GenServer
  def handle_info(:advance_handoff, state), do: {:noreply, maybe_start_turn(state)}

  def handle_info({:handed_off, successor}, state) do
    if Keyword.get(state.opts, :start_successor, true) do
      case Conversations.start(successor, state.opts) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          Logger.error("conversation #{successor.id} not started: #{inspect(reason, limit: 8)}")
      end
    end

    {:stop, :normal, state}
  end

  def handle_info(:poll, state) do
    state = check_dispatches(state)
    schedule_poll(state)
    {:noreply, state}
  end

  def handle_info(
        {:conversation_event, pid, %ConversationEvent{} = event},
        %{adapter: pid} = state
      ),
      do: {:noreply, coordinator_event(state, event)}

  # From a coordinator process this engine no longer uses.
  def handle_info({:conversation_event, _pid, _event}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, _reason}, %{adapter: pid} = state) do
    state =
      if state.turn,
        do: end_turn(state, state.turn.id, "uncertain", "coordinator_exited"),
        else: state

    {:noreply, maybe_start_turn(%{state | adapter: nil})}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    if state.adapter, do: state.module.close(state.adapter)

    if state.turn,
      do:
        record(
          state,
          "conversation.turn.ended",
          ended(state.turn.id, "uncertain", "conversation_stopped"),
          "turn-ended:#{state.turn.id}",
          "conversation"
        )

    if state.token, do: ToolTokens.revoke(state.token)
    :ok
  end

  # -- Turns -----------------------------------------------------------------

  defp maybe_start_turn(%{turn: nil, history: %{open_turn: nil, handoff: %{}}} = state),
    do: advance_handoff(state)

  defp maybe_start_turn(%{turn: nil, history: %{open_turn: nil}} = state) do
    pending = History.pending(state.history)

    cond do
      pending == %{messages: [], inbox: []} -> state
      # A received handoff waits for the person's next message.
      pending.inbox == [] and Enum.all?(pending.messages, &(&1.kind == :handoff)) -> state
      true -> start_turn(state, pending)
    end
  end

  defp maybe_start_turn(state), do: state

  # -- Handoff ---------------------------------------------------------------

  defp advance_handoff(%{history: %{handoff: handoff}} = state) do
    request = Enum.find(state.history.messages, &(&1.id == handoff.id))

    cond do
      handoff.status == :prepared ->
        switch(state)

      handoff.status == :done ->
        state

      # The instruction, after any handoff this conversation received and
      # never delivered; what the person sends meanwhile is carried over.
      request != nil and not History.delivered?(state.history, request.id) ->
        received = Enum.filter(History.pending(state.history).messages, &(&1.kind == :handoff))
        start_turn(state, %{messages: received ++ [request], inbox: []})

      true ->
        prepare_handoff(state)
    end
  end

  defp prepare_handoff(state) do
    payload =
      Handoff.prepare(
        state.conversation,
        state.history,
        state.history.handoff.id,
        DateTime.utc_now()
      )

    case record(
           state,
           "conversation.handoff.prepared",
           payload,
           "handoff-prepared",
           "conversation"
         ) do
      {:ok, state} -> switch(state)
      # Prepared again on a later poll.
      {:error, _reason} -> state
    end
  end

  defp switch(state) do
    case Conversations.hand_off(state.conversation, state.history.handoff.prepared) do
      {:ok, successor} ->
        send(self(), {:handed_off, successor})
        %{state | history: %{state.history | handoff: %{state.history.handoff | status: :done}}}

      # Tried again on a later poll.
      {:error, reason} ->
        Logger.error(
          "conversation #{state.conversation.id} not handed off: #{inspect(reason, limit: 8)}"
        )

        state
    end
  end

  # The text bound, with room for the handoff turn's instruction and note.
  defp context_limit(%{history: %{handoff: %{}}} = state),
    do: state.max_context_bytes + Handoff.headroom()

  defp context_limit(state), do: state.max_context_bytes

  defp start_turn(state, pending) do
    pending = pending_batch(pending, state.max_input_bytes)

    cond do
      state.history.visible_bytes >= context_limit(state) ->
        hold(state, "context_limit_reached", %{})

      pending == %{messages: [], inbox: []} ->
        hold(state, "input_too_large", %{})

      true ->
        start_admitted_turn(state, pending)
    end
  end

  defp start_admitted_turn(state, pending) do
    turn_id = Ecto.UUID.generate()

    with {:ok, grant} <- grant(state),
         {:ok, admission} <- admit(state, grant),
         {:ok, grant} <- charge(state, grant, turn_id) do
      payload = %{
        "turn_id" => turn_id,
        "message_ids" => Enum.map(pending.messages, & &1.id),
        "inbox_ids" => Enum.map(pending.inbox, & &1.id),
        "grant_id" => grant.id,
        "admission" => admission
      }

      case record(
             state,
             "conversation.turn.requested",
             payload,
             "turn-requested:#{turn_id}",
             "conversation"
           ) do
        {:ok, state} ->
          send_turn(state, grant, turn_id, turn_text(pending))

        # Nothing was handed over; the inputs stay pending for the next turn.
        {:error, _reason} ->
          refund(state, grant, turn_id)
          state
      end
    else
      {:hold, reason, detail} -> hold(state, reason, detail)
    end
  end

  defp grant(state) do
    case Grants.active(state.conversation.session_id) do
      nil -> {:hold, "no_grant", %{}}
      grant -> {:ok, grant}
    end
  end

  # A turn is a `read_only` call of the coordinator's provider on its
  # subscription, admitted against the standing reserves like an EXPLORE or
  # REVIEW call. The grant's turns are the person's attributable
  # confirmation, so unknown or unread usage does not hold a granted turn; a
  # breached reserve still defers it, with no other model or provider.
  defp admit(state, grant) do
    provider = state.conversation.provider
    now = DateTime.utc_now()

    {:ok, decision} =
      AdmissionEvaluation.evaluate(
        %{
          requested_capability: "read_only",
          scope: @scope,
          override: %{
            "confirmed_by" => Authority.grant_identity(grant.id),
            "confirmed_at" => DateTime.to_iso8601(now),
            "intent" => "coordinator_turn"
          }
        },
        %{
          provider_id: provider,
          adapter_id: "converse.#{provider}",
          scope: @scope,
          support_tier: :conservative_partial,
          compatibility_state: :compatible,
          capabilities: ["read_only"]
        },
        observation(provider),
        nil,
        now: now
      )

    case decision.result do
      :admit ->
        {:ok,
         %{
           "decision_id" => decision.decision_id,
           "result" => "admit",
           "reason_code" => decision.reason_code
         }}

      :defer_until ->
        {:hold, decision.reason_code,
         %{"grant_id" => grant.id, "defer_until" => DateTime.to_iso8601(decision.defer_until)}}

      _held_or_rejected ->
        {:hold, decision.reason_code, %{"grant_id" => grant.id}}
    end
  end

  defp observation(provider) do
    case WakeupObserve.observe(%{provider_id: provider, scope: @scope}) do
      {:ok, snapshot} -> snapshot
      _ -> nil
    end
  end

  defp charge(state, grant, turn_id) do
    case Grants.use_turn(grant, turn_detail(state, turn_id)) do
      {:ok, grant} -> {:ok, grant}
      {:error, :turns_exhausted} -> {:hold, "turns_exhausted", %{"grant_id" => grant.id}}
      {:error, _reason} -> {:hold, "grant_unavailable", %{"grant_id" => grant.id}}
    end
  end

  defp refund(state, grant, turn_id), do: Grants.refund_turn(grant, turn_detail(state, turn_id))

  defp turn_detail(state, turn_id),
    do: %{"turn_id" => turn_id, "conversation_id" => state.conversation.id}

  # Recorded once per reason, so a poll that finds the same hold records
  # nothing; the pending input stays pending.
  defp hold(%{history: %{hold: %{reason: reason}}} = state, reason, _detail), do: state

  defp hold(state, reason, detail) do
    case record(
           state,
           "conversation.turn.held",
           Map.put(detail, "reason", reason),
           "held:#{Ecto.UUID.generate()}",
           "conversation"
         ) do
      {:ok, state} -> state
      {:error, _reason} -> state
    end
  end

  defp send_turn(state, grant, turn_id, text) do
    case ensure_coordinator(state) do
      {:ok, state} ->
        case state.module.send_turn(state.adapter, turn_id, text) do
          :ok ->
            %{
              state
              | turn: %{
                  id: turn_id,
                  item: 0,
                  failure: nil,
                  reply: [],
                  reply_item: nil,
                  buffer_bytes: 0,
                  reply_bytes: 0
                }
            }

          # A closed session may have taken the turn before it went away, so
          # the turn stays charged.
          {:error, %Error{code: "conversation_closed"}} ->
            end_turn(%{state | adapter: nil}, turn_id, "uncertain", "conversation_closed")

          {:error, error} ->
            refund(state, grant, turn_id)
            end_turn(state, turn_id, "unsent", reason_code(error))
        end

      {:error, reason, state} ->
        refund(state, grant, turn_id)
        end_turn(state, turn_id, "unsent", reason_code(reason))
    end
  end

  defp ensure_coordinator(%{adapter: pid} = state) when is_pid(pid), do: {:ok, state}

  defp ensure_coordinator(state) do
    %{conversation: conversation, opts: opts} = state
    token = state.token || ToolTokens.issue(tool_binding(conversation))
    state = %{state | token: token}

    tools =
      case Keyword.get_lazy(opts, :tools_url, &default_tools_url/0) do
        nil -> nil
        url -> %{url: url, token: token}
      end

    spec = %{
      owner: self(),
      workdir: conversation.repository_root,
      model: conversation.model,
      effort: conversation.effort,
      instructions: Keyword.get_lazy(opts, :instructions, fn -> instructions(conversation) end),
      tools: tools,
      resume: state.history.provider_session_id
    }

    case state.module.start_link(spec, Keyword.get(opts, :conversation_opts, [])) do
      {:ok, pid} -> {:ok, %{state | adapter: pid}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # Written by `shoestring chat`; read again at each start, so a resumed
  # coordinator gets the instructions its session was opened with.
  defp instructions(conversation) do
    case File.read(Conversations.instructions_path(conversation.session_id)) do
      {:ok, text} -> text
      {:error, _} -> nil
    end
  end

  defp tool_binding(conversation),
    do: %{session_id: conversation.session_id, repository: conversation.repository_root}

  defp default_tools_url, do: ShoestringWeb.Endpoint.url() <> "/mcp"

  defp turn_text(%{messages: messages, inbox: inbox}) do
    said = Enum.map(messages, & &1.text)

    notices =
      Enum.map(inbox, fn entry ->
        "Shoestring inbox: dispatch #{entry.dispatch_id} (#{entry.purpose} \"#{entry.title}\" " <>
          "on #{entry.worker}) is now #{entry.state}. runs_show gives its detail."
      end)

    Enum.join(said ++ notices, "\n\n")
  end

  defp pending_batch(pending, max_bytes) do
    entries =
      Enum.map(pending.messages, &{:messages, &1}) ++ Enum.map(pending.inbox, &{:inbox, &1})

    Enum.reduce_while(entries, %{messages: [], inbox: []}, fn {kind, entry}, batch ->
      candidate = Map.update!(batch, kind, &(&1 ++ [entry]))

      if byte_size(turn_text(candidate)) <= max_bytes,
        do: {:cont, candidate},
        else: {:halt, batch}
    end)
  end

  defp coordinator_event(state, %ConversationEvent{type: :session, provider_session_id: id})
       when is_binary(id) do
    if id == state.history.provider_session_id,
      do: state,
      else:
        record!(
          state,
          "conversation.provider_session.bound",
          %{"provider_session_id" => id},
          "provider-session:#{id}"
        )
  end

  defp coordinator_event(
         %{turn: %{id: id} = turn} = state,
         %ConversationEvent{turn_id: id} = event
       ) do
    case event.type do
      :text ->
        reply(state, turn, event)

      :tool_call ->
        tool_called(state, turn, event)

      :tool_result ->
        tool_returned(state, turn, event)

      :turn_completed ->
        completed(state, turn, event)

      :closed ->
        reason =
          if event.reason == :provider_session_changed,
            do: "provider_session_changed",
            else: "coordinator_closed"

        end_turn(%{state | adapter: nil}, id, "uncertain", reason)

      _ ->
        state
    end
  end

  # A turn this engine is not running (or none): only the session matters.
  defp coordinator_event(state, %ConversationEvent{type: :closed}), do: %{state | adapter: nil}
  defp coordinator_event(state, _event), do: state

  defp reply(state, %{failure: failure}, _event) when not is_nil(failure), do: state
  defp reply(state, _turn, %ConversationEvent{text: "", text_complete: false}), do: state

  defp reply(state, turn, event) do
    text = event.text || ""
    bytes = turn.reply_bytes + byte_size(text)

    failure =
      cond do
        bytes > state.max_reply_bytes ->
          "reply_too_large"

        state.history.visible_bytes + turn.buffer_bytes + byte_size(text) >
            context_limit(state) ->
          "context_limit_reached"

        true ->
          nil
      end

    if failure do
      :ok = state.module.cancel_turn(state.adapter)
      %{state | turn: %{turn | failure: failure, reply: [], buffer_bytes: 0}}
    else
      state =
        if turn.reply != [] and event.text_item != nil and turn.reply_item != event.text_item,
          do: flush_reply(state),
          else: state

      case state.turn do
        %{failure: nil} = turn ->
          turn = %{
            turn
            | reply: [text | turn.reply],
              reply_item: event.text_item,
              buffer_bytes: turn.buffer_bytes + byte_size(text),
              reply_bytes: bytes
          }

          state = %{state | turn: turn}
          if event.text_complete, do: flush_reply(state), else: state

        _ ->
          state
      end
    end
  end

  # Persist only complete, assembled visible messages. Redacting individual
  # transport deltas can expose a credential split at any chunk boundary.
  defp flush_reply(%{turn: nil} = state), do: state

  defp flush_reply(%{turn: %{failure: failure} = turn} = state) when not is_nil(failure),
    do: %{state | turn: %{turn | reply: [], buffer_bytes: 0}}

  defp flush_reply(%{turn: %{reply: []}} = state), do: state

  defp flush_reply(state) do
    turn = state.turn
    text = turn.reply |> Enum.reverse() |> IO.iodata_to_binary()

    if text == "" do
      %{state | turn: %{turn | reply: [], reply_item: nil, buffer_bytes: 0}}
    else
      text = Redaction.redact(text)

      if state.history.visible_bytes + byte_size(text) > context_limit(state) do
        if state.adapter, do: state.module.cancel_turn(state.adapter)
        %{state | turn: %{turn | failure: "context_limit_reached", reply: [], buffer_bytes: 0}}
      else
        payload = %{"turn_id" => turn.id, "item" => turn.item, "text" => text}

        state =
          record!(
            state,
            "conversation.message.coordinator",
            payload,
            "reply:#{turn.id}:#{turn.item}",
            "coordinator"
          )

        %{
          state
          | turn: %{turn | item: turn.item + 1, reply: [], reply_item: nil, buffer_bytes: 0}
        }
      end
    end
  end

  defp tool_called(state, turn, event) do
    state = flush_reply(state)
    payload = %{"turn_id" => turn.id, "call_id" => event.tool_call_id, "tool" => event.tool}

    record!(
      state,
      "conversation.tool.called",
      payload,
      "tool-called:#{turn.id}:#{event.tool_call_id}",
      "coordinator"
    )
  end

  defp tool_returned(state, turn, event) do
    payload = %{
      "turn_id" => turn.id,
      "call_id" => event.tool_call_id,
      "is_error" => event.is_error == true
    }

    record!(
      state,
      "conversation.tool.returned",
      payload,
      "tool-returned:#{turn.id}:#{event.tool_call_id}",
      "conversation"
    )
  end

  defp completed(state, _turn, event) do
    state = flush_reply(state)
    turn = state.turn

    {status, reason} =
      case turn.failure do
        nil -> {Atom.to_string(event.status), event.reason && reason_code(event.reason)}
        failure -> {"failed", failure}
      end

    state
    |> end_turn(turn.id, status, reason, event.usage)
    |> maybe_start_turn()
  end

  defp end_turn(state, turn_id, status, reason, usage \\ %{}) do
    state = flush_reply(state)

    state =
      record!(
        state,
        "conversation.turn.ended",
        ended(turn_id, status, reason, usage),
        "turn-ended:#{turn_id}"
      )

    %{state | turn: nil}
  end

  defp ended(turn_id, status, reason, usage \\ %{}) do
    counts =
      for {key, value} <- usage || %{}, is_integer(value), into: %{}, do: {to_string(key), value}

    %{"turn_id" => turn_id, "status" => status}
    |> then(&if(reason, do: Map.put(&1, "reason", reason), else: &1))
    |> then(&if(counts == %{}, do: &1, else: Map.put(&1, "usage", counts)))
  end

  defp reason_code(%Error{code: code}) when is_binary(code), do: code
  defp reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_code(reason) when is_binary(reason), do: reason
  defp reason_code({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_code(_reason), do: "error"

  # -- Inbox -----------------------------------------------------------------

  defp check_dispatches(state) do
    state.conversation.session_id
    |> Dispatches.list()
    |> Enum.reject(&History.final?(state.history, &1.id))
    |> Enum.reduce(state, fn dispatch, state ->
      # A hold the grant pre-approved is confirmed here, so it is not settled.
      _ = Dispatches.advance(dispatch)
      {settled, settlement_ref} = Dispatches.inbox_state(dispatch)

      if settled in Events.inbox_states() and
           not History.recorded?(state.history, dispatch.id, settled, settlement_ref),
         do: inbox(state, dispatch, settled, settlement_ref),
         else: state
    end)
    |> maybe_start_turn()
  end

  defp inbox(state, dispatch, settled, settlement_ref) do
    payload = %{
      "entry_id" => Ecto.UUID.generate(),
      "dispatch_id" => dispatch.id,
      "state" => settled,
      "settlement_ref" => settlement_ref,
      "purpose" => dispatch.purpose,
      "title" => Redaction.redact(dispatch.title),
      "worker" => "#{dispatch.provider}:#{dispatch.model}"
    }

    case record(
           state,
           "conversation.inbox.recorded",
           payload,
           "inbox:#{dispatch.id}:#{settled}:#{settlement_ref}",
           "conversation"
         ) do
      {:ok, state} -> state
      # Recorded on a later poll.
      {:error, _reason} -> state
    end
  end

  defp schedule_poll(%{poll_ms: ms}) when is_integer(ms) and ms > 0,
    do: Process.send_after(self(), :poll, ms)

  defp schedule_poll(_state), do: :ok

  # -- Events ----------------------------------------------------------------

  defp record(state, type, payload, key, actor) do
    attrs = %{
      "type" => type,
      "schema_version" => 1,
      "actor" => actor,
      "idempotency_key" => key,
      "payload" => payload
    }

    case Trajectory.append(state.conversation.id, attrs) do
      {:ok, event} ->
        # A replayed key returns the event already folded in.
        if event.sequence > state.history.last_sequence,
          do: {:ok, %{state | history: History.apply_event(state.history, event)}},
          else: {:ok, state}

      {:error, reason} = error ->
        Logger.error(
          "conversation #{state.conversation.id} could not record #{type}: #{inspect(reason)}"
        )

        error
    end
  end

  # Inside a turn a fact that cannot be recorded stops the engine: its
  # restart ends the turn `uncertain`, so nothing is lost without saying so.
  defp record!(state, type, payload, key, actor \\ "conversation") do
    case record(state, type, payload, key, actor) do
      {:ok, state} -> state
      {:error, reason} -> raise "conversation event #{type} not recorded: #{inspect(reason)}"
    end
  end
end
