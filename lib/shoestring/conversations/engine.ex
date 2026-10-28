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
    * An oversized message is refused before it is recorded. An oversized
      coordinator reply interrupts the turn, which ends `failed` with reason
      `reply_too_large`; nothing is truncated.

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
  the first time a dispatch is seen in each settled state. The poll never
  interrupts a turn; entries wait for the coordinator to be idle.

  **Restart.** A new engine rebuilds its history from events without a
  model call and starts no turn by itself. The coordinator process is
  started at the first turn, resuming the provider session recorded in
  `conversation.provider_session.bound`.

  Options: `:conversation_module` (default: the provider's `:converse`
  module), `:conversation_opts`, `:instructions`, `:tools_url` (default the
  endpoint's `/mcp`; nil for no tools), `:poll_ms` (nil turns the timer off;
  `poll/1` still works), `:max_reply_bytes` (default 256 KiB).
  """

  use GenServer, restart: :transient

  require Logger

  alias Shoestring.{Authority, Dispatches, Grants, Harnesses, Trajectory}
  alias Shoestring.Cobbler.{AdmissionEvaluation, WakeupObserve}
  alias Shoestring.Conversations.{Conversation, Events, History}
  alias Shoestring.Coordinator.ToolTokens
  alias Shoestring.Harness.{ConversationEvent, Error}
  alias Shoestring.Trajectory.Redaction

  @max_message_bytes 32_768
  @max_reply_bytes 262_144
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
         {:ok, events} <- Trajectory.replay(conversation.id) do
      state = %{
        conversation: conversation,
        history: History.from_events(events),
        module: module,
        opts: opts,
        adapter: nil,
        token: nil,
        turn: nil,
        poll_ms: Keyword.get(opts, :poll_ms, @poll_ms),
        max_reply_bytes: Keyword.get(opts, :max_reply_bytes, @max_reply_bytes)
      }

      state =
        case state.history.open_turn do
          nil -> state
          turn_id -> end_turn(state, turn_id, "uncertain", "service_restarted")
        end

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
    cond do
      byte_size(text) > @max_message_bytes ->
        {:reply, {:error, :message_too_large}, state}

      String.trim(text) == "" ->
        {:reply, {:error, :empty_message}, state}

      true ->
        payload = %{"message_id" => message_id, "text" => Redaction.redact(text)}

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
       hold: state.history.hold && state.history.hold.reason
     }, state}
  end

  def handle_call(:history, _from, state), do: {:reply, state.history, state}
  def handle_call(:poll, _from, state), do: {:reply, :ok, check_dispatches(state)}

  @impl GenServer
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

  defp maybe_start_turn(%{turn: nil, history: %{open_turn: nil}} = state) do
    case History.pending(state.history) do
      %{messages: [], inbox: []} -> state
      pending -> start_turn(state, pending)
    end
  end

  defp maybe_start_turn(state), do: state

  defp start_turn(state, pending) do
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
            %{state | turn: %{id: turn_id, item: 0, failure: nil}}

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
      instructions: Keyword.get(opts, :instructions),
      tools: tools,
      resume: state.history.provider_session_id
    }

    case state.module.start_link(spec, Keyword.get(opts, :conversation_opts, [])) do
      {:ok, pid} -> {:ok, %{state | adapter: pid}}
      {:error, reason} -> {:error, reason, state}
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
      :text -> reply(state, turn, event.text || "")
      :tool_call -> tool_called(state, turn, event)
      :tool_result -> tool_returned(state, turn, event)
      :turn_completed -> completed(state, turn, event)
      :closed -> end_turn(%{state | adapter: nil}, id, "uncertain", "coordinator_closed")
      _ -> state
    end
  end

  # A turn this engine is not running (or none): only the session matters.
  defp coordinator_event(state, %ConversationEvent{type: :closed}), do: %{state | adapter: nil}
  defp coordinator_event(state, _event), do: state

  defp reply(state, %{failure: failure}, _text) when not is_nil(failure), do: state

  defp reply(%{max_reply_bytes: max} = state, turn, text) when byte_size(text) > max do
    :ok = state.module.cancel_turn(state.adapter)
    %{state | turn: %{turn | failure: "reply_too_large"}}
  end

  defp reply(state, turn, text) do
    payload = %{"turn_id" => turn.id, "item" => turn.item, "text" => Redaction.redact(text)}

    state =
      record!(
        state,
        "conversation.message.coordinator",
        payload,
        "reply:#{turn.id}:#{turn.item}",
        "coordinator"
      )

    %{state | turn: %{turn | item: turn.item + 1}}
  end

  defp tool_called(state, turn, event) do
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

  defp completed(state, turn, event) do
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
      settled = Dispatches.state(dispatch)

      if settled in Events.inbox_states() and
           not History.recorded?(state.history, dispatch.id, settled),
         do: inbox(state, dispatch, settled),
         else: state
    end)
    |> maybe_start_turn()
  end

  defp inbox(state, dispatch, settled) do
    payload = %{
      "entry_id" => Ecto.UUID.generate(),
      "dispatch_id" => dispatch.id,
      "state" => settled,
      "purpose" => dispatch.purpose,
      "title" => Redaction.redact(dispatch.title),
      "worker" => "#{dispatch.provider}:#{dispatch.model}"
    }

    case record(
           state,
           "conversation.inbox.recorded",
           payload,
           "inbox:#{dispatch.id}:#{settled}",
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
