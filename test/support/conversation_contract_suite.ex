defmodule Shoestring.Harness.ConversationContractSuite do
  @moduledoc """
  The contract every `Shoestring.Harness.Conversation` module must pass
  (iteration 15, package A), run against Fake and scripted transports.

  ## Usage

      defmodule MyConversationContractTest do
        use ExUnit.Case, async: true
        use Shoestring.Harness.ConversationContractSuite, module: MyConversation

        # Opens a conversation for `spec` (owner, workdir and model already
        # set). A model named "not-a-model" must be refused at start.
        def open(spec, context), do: MyConversation.start_link(spec, [])
      end

  The turn texts are the scripted directives both Fake and the scripted
  CLIs understand: `SAY`, `CALL`, `SLOW`, `FAIL`.
  """

  import ExUnit.Assertions

  alias Shoestring.Harness.{ConversationEvent, Error}

  @doc "Receives the next event from `pid`, or fails after `timeout`."
  def next_event(pid, timeout \\ 5_000) do
    receive do
      {:conversation_event, ^pid, %ConversationEvent{} = event} -> event
    after
      timeout -> flunk("no conversation event from #{inspect(pid)} within #{timeout} ms")
    end
  end

  @doc "Receives events until one of `type` arrives; returns all of them."
  def events_until(pid, type, timeout \\ 5_000) do
    event = next_event(pid, timeout)
    if event.type == type, do: [event], else: [event | events_until(pid, type, timeout)]
  end

  @doc "Asserts ordinals increase by one."
  def assert_ordered(events) do
    ordinals = Enum.map(events, & &1.ordinal)
    assert ordinals == Enum.to_list(hd(ordinals)..(hd(ordinals) + length(ordinals) - 1))
  end

  defmacro __using__(opts) do
    module = Keyword.fetch!(opts, :module)

    quote do
      import Shoestring.Harness.ConversationContractSuite

      alias Shoestring.Harness.{ConversationEvent, Error}

      @conversation unquote(module)

      defp spec(context, overrides \\ %{}) do
        Map.merge(%{owner: self(), workdir: context.tmp_dir, model: "opus"}, overrides)
      end

      defp open!(context, overrides \\ %{}) do
        {:ok, pid} = open(spec(context, overrides), context)
        on_exit(fn -> @conversation.close(pid) end)
        %ConversationEvent{type: :session} = next_event(pid)
        pid
      end

      @tag :tmp_dir
      test "opens, reports its session and is idle", context do
        {:ok, pid} = open(spec(context), context)
        on_exit(fn -> @conversation.close(pid) end)

        event = next_event(pid)
        assert event.type == :session and event.ordinal == 1
        assert is_binary(event.provider_session_id) and event.provider_session_id != ""

        assert %{state: :idle, turn_id: nil, provider_session_id: id} = @conversation.status(pid)
        assert id == event.provider_session_id
      end

      @tag :tmp_dir
      test "a turn reports its text, then completes once", context do
        pid = open!(context)
        assert :ok = @conversation.send_turn(pid, "turn-1", "SAY hello there")

        events = events_until(pid, :turn_completed)
        assert_ordered(events)
        assert [%{type: :turn_started, turn_id: "turn-1"} | _] = events
        assert Enum.any?(events, &(&1.type == :text and &1.text == "hello there"))
        assert %{type: :turn_completed, status: :completed, turn_id: "turn-1"} = List.last(events)
        assert Enum.all?(events, &(&1.turn_id == "turn-1"))
        assert %{state: :idle, turn_id: nil} = @conversation.status(pid)
      end

      @tag :tmp_dir
      test "a tool call carries its name and ids only", context do
        pid = open!(context)
        :ok = @conversation.send_turn(pid, "turn-1", "CALL mcp__shoestring__dispatch")

        events = events_until(pid, :turn_completed)

        assert %{tool: "mcp__shoestring__dispatch", tool_call_id: call} =
                 Enum.find(events, &(&1.type == :tool_call))

        assert %{is_error: false} =
                 Enum.find(events, &(&1.type == :tool_result and &1.tool_call_id == call))

        assert %{status: :completed} = List.last(events)
      end

      @tag :tmp_dir
      test "a turn sent while one runs is refused, not queued", context do
        pid = open!(context)
        :ok = @conversation.send_turn(pid, "turn-1", "SLOW 3000 late")
        assert %{type: :turn_started} = next_event(pid)

        assert {:error, %Error{code: "turn_in_progress"}} =
                 @conversation.send_turn(pid, "turn-2", "SAY too soon")

        assert %{state: :in_turn, turn_id: "turn-1"} = @conversation.status(pid)
        :ok = @conversation.cancel_turn(pid)

        assert %{type: :turn_completed, turn_id: "turn-1"} =
                 List.last(events_until(pid, :turn_completed))

        refute_received {:conversation_event, ^pid, %{turn_id: "turn-2"}}
      end

      @tag :tmp_dir
      test "cancel interrupts the running turn and the session stays open", context do
        pid = open!(context)
        :ok = @conversation.send_turn(pid, "turn-1", "SLOW 5000 never shown")
        assert %{type: :turn_started} = next_event(pid)
        :ok = @conversation.cancel_turn(pid)

        events = events_until(pid, :turn_completed, 3_000)
        assert %{status: :interrupted, turn_id: "turn-1"} = List.last(events)
        refute Enum.any?(events, &(&1.type == :text and &1.text == "never shown"))

        :ok = @conversation.send_turn(pid, "turn-2", "SAY still here")

        assert %{status: :completed, turn_id: "turn-2"} =
                 List.last(events_until(pid, :turn_completed))
      end

      @tag :tmp_dir
      test "cancel with no turn running does nothing", context do
        pid = open!(context)
        assert :ok = @conversation.cancel_turn(pid)
        refute_receive {:conversation_event, ^pid, _}, 200
        assert %{state: :idle} = @conversation.status(pid)
      end

      @tag :tmp_dir
      test "a failed turn is reported and the next turn runs", context do
        pid = open!(context)
        :ok = @conversation.send_turn(pid, "turn-1", "FAIL")
        assert %{status: :failed} = List.last(events_until(pid, :turn_completed))

        :ok = @conversation.send_turn(pid, "turn-2", "SAY again")
        assert %{status: :completed} = List.last(events_until(pid, :turn_completed))
      end

      @tag :tmp_dir
      test "close ends with :closed naming the open turn; later turns are refused", context do
        pid = open!(context)
        ref = Process.monitor(pid)
        :ok = @conversation.send_turn(pid, "turn-1", "SLOW 5000 never shown")
        assert %{type: :turn_started} = next_event(pid)

        assert :ok = @conversation.close(pid)
        assert %{type: :closed, turn_id: "turn-1"} = List.last(events_until(pid, :closed))
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 10_000

        assert {:error, %Error{code: "conversation_closed"}} =
                 @conversation.send_turn(pid, "turn-2", "SAY too late")

        assert :ok = @conversation.close(pid)
        assert :ok = @conversation.cancel_turn(pid)
        assert %{state: :closed} = @conversation.status(pid)
      end

      @tag :tmp_dir
      test "resume reports the session it continues", context do
        {:ok, pid} =
          open(spec(context, %{resume: "11111111-2222-4333-8444-555555555555"}), context)

        on_exit(fn -> @conversation.close(pid) end)

        assert %{type: :session, provider_session_id: "11111111-2222-4333-8444-555555555555"} =
                 next_event(pid)
      end

      @tag :tmp_dir
      test "a model the harness does not offer is refused before any turn", context do
        assert {:error, %Error{code: "model_not_offered"}} =
                 open(spec(context, %{model: "not-a-model"}), context)

        refute_receive {:conversation_event, _, _}, 100
      end

      @tag :tmp_dir
      test "a spec without a model or workdir is refused", context do
        assert {:error, %Error{code: "model_required"}} =
                 open(spec(context, %{model: nil}), context)

        assert {:error, %Error{code: "invalid_workdir"}} =
                 open(spec(context, %{workdir: Path.join(context.tmp_dir, "missing")}), context)
      end
    end
  end
end
