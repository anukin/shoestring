defmodule Shoestring.Harness.Fake.Conversation do
  @moduledoc """
  A deterministic `Shoestring.Harness.Conversation` for offline tests. No
  process, network or credentials.

  Each turn's text chooses the reply, with the same directives as the
  scripted CLIs the conversation contract suite drives:

    * `SAY text` — replies `text`.
    * `CALL tool` — calls `tool`, gets a successful result, replies `RESULT`.
    * `SLOW ms text` — replies `text` after `ms` milliseconds (so a turn can
      be interrupted while it runs).
    * `FAIL` — the turn fails.
    * anything else — replies `ACK`.

  Options: `:session_id` (the provider session id a fresh session reports;
  default `"fake-conversation-session"`), `:refuse_model` (a model name
  whose selection is refused, as a harness refuses a model it does not
  offer), `:script` (a function from a turn's whole text to the directive
  it runs, for turns whose text a test does not write) and `:observer` (a
  pid sent `{:fake_conversation_turn, text}` for every turn).
  """

  @behaviour Shoestring.Harness.Conversation

  use GenServer

  alias Shoestring.Harness.{Conversation, ConversationEvent, Error}

  @impl Conversation
  def start_link(spec, opts \\ []) do
    with :ok <- Conversation.validate(spec),
         :ok <- model_offered(spec, opts) do
      GenServer.start_link(__MODULE__, {spec, opts})
    end
  end

  @impl Conversation
  def send_turn(pid, turn_id, text) when is_binary(turn_id) and is_binary(text) do
    GenServer.call(pid, {:turn, turn_id, text})
  catch
    :exit, _ -> {:error, Conversation.closed()}
  end

  @impl Conversation
  def cancel_turn(pid) do
    GenServer.call(pid, :cancel_turn)
  catch
    :exit, _ -> :ok
  end

  @impl Conversation
  def close(pid) do
    GenServer.call(pid, :close)
  catch
    :exit, _ -> :ok
  end

  @impl Conversation
  def status(pid) do
    GenServer.call(pid, :status)
  catch
    :exit, _ -> %{state: :closed, turn_id: nil, provider_session_id: nil}
  end

  defp model_offered(%{model: model}, opts) do
    if model == Keyword.get(opts, :refuse_model),
      do:
        {:error,
         Error.new(
           :schema_incompatible,
           "model_not_offered",
           "The harness does not offer #{model}"
         )},
      else: :ok
  end

  # --- Server ---

  @impl GenServer
  def init({spec, opts}) do
    session = spec[:resume] || Keyword.get(opts, :session_id, "fake-conversation-session")

    state = %{
      owner: spec.owner,
      script: Keyword.get(opts, :script, & &1),
      observer: Keyword.get(opts, :observer),
      ordinal: 0,
      turn: nil,
      timer: nil,
      session: session,
      state: :idle
    }

    {:ok, emit(state, :session, provider_session_id: session)}
  end

  @impl GenServer
  def handle_call({:turn, _turn_id, _text}, _from, %{turn: running} = state)
      when not is_nil(running),
      do: {:reply, {:error, Conversation.turn_in_progress(running)}, state}

  def handle_call({:turn, turn_id, text}, _from, state) do
    if state.observer, do: send(state.observer, {:fake_conversation_turn, text})
    state = emit(%{state | turn: turn_id, state: :in_turn}, :turn_started, turn_id: turn_id)
    {:reply, :ok, run(state, String.trim(state.script.(text)))}
  end

  def handle_call(:cancel_turn, _from, %{turn: nil} = state), do: {:reply, :ok, state}

  def handle_call(:cancel_turn, _from, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {:reply, :ok, complete(%{state | timer: nil}, :interrupted)}
  end

  def handle_call(:close, _from, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    state = emit(state, :closed, reason: :normal, turn_id: state.turn)
    {:stop, :normal, :ok, state}
  end

  def handle_call(:status, _from, state),
    do:
      {:reply, %{state: state.state, turn_id: state.turn, provider_session_id: state.session},
       state}

  @impl GenServer
  def handle_info({:slow_reply, turn_id, text}, %{turn: turn_id} = state),
    do: {:noreply, state |> emit(:text, turn_id: turn_id, text: text) |> complete(:completed)}

  def handle_info({:slow_reply, _turn_id, _text}, state), do: {:noreply, state}

  defp run(state, "SAY " <> text),
    do: state |> emit(:text, turn_id: state.turn, text: text) |> complete(:completed)

  defp run(state, "CALL " <> tool) do
    call = "fake-call-#{state.ordinal}"

    state
    |> emit(:tool_call, turn_id: state.turn, tool: String.trim(tool), tool_call_id: call)
    |> emit(:tool_result, turn_id: state.turn, tool_call_id: call, is_error: false)
    |> emit(:text, turn_id: state.turn, text: "RESULT")
    |> complete(:completed)
  end

  defp run(state, "SLOW " <> rest) do
    {ms, text} =
      case String.split(rest, " ", parts: 2) do
        [ms, text] -> {String.to_integer(ms), text}
        [ms] -> {String.to_integer(ms), ""}
      end

    %{state | timer: Process.send_after(self(), {:slow_reply, state.turn, text}, ms)}
  end

  defp run(state, "FAIL"), do: complete(state, :failed)

  defp run(state, _text),
    do: state |> emit(:text, turn_id: state.turn, text: "ACK") |> complete(:completed)

  defp complete(state, status) do
    state
    |> emit(:turn_completed, turn_id: state.turn, status: status, usage: %{})
    |> Map.merge(%{turn: nil, timer: nil, state: :idle})
  end

  defp emit(state, type, fields) do
    ordinal = state.ordinal + 1
    send(state.owner, {:conversation_event, self(), ConversationEvent.new(type, ordinal, fields)})
    %{state | ordinal: ordinal}
  end
end
