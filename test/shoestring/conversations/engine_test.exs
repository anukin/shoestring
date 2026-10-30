defmodule Shoestring.Conversations.EngineTest do
  @moduledoc """
  The conversation engine against `Shoestring.Harness.Fake.Conversation`, a
  real temporary Git repository and a grant made the way a person makes one,
  with Oban in manual testing mode: no service, provider or network. Every
  assertion reads the trajectory events or the history rebuilt from them.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.{Conversations, ModelCatalog, Repo, Trajectory}
  alias Shoestring.CLI.Commands.Grant
  alias Shoestring.Conversations.{Engine, History}
  alias Shoestring.Coordinator.Tools
  alias Shoestring.Harness.Fake

  @brief "IMPLEMENT - make add() return the sum\nContract: test/test_calc.py passes.\n"

  setup ctx do
    repo = Path.join(System.tmp_dir!(), "shoestring-engine-#{Ecto.UUID.generate()}")
    File.mkdir_p!(Path.join(repo, "test"))
    on_exit(fn -> File.rm_rf!(repo) end)
    File.write!(Path.join(repo, "calc.py"), "def add(a, b):\n    raise NotImplementedError\n")
    File.write!(Path.join(repo, "test/test_calc.py"), "import unittest\n")
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["add", "."])
    git!(repo, ["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qm", "base"])

    {:ok, conversation} =
      Conversations.open(%{
        session_id: "s1",
        provider: ctx[:provider] || "claude",
        model: ctx[:model] || "claude-test-model",
        effort: nil,
        repository_root: repo
      })

    Phoenix.PubSub.subscribe(Shoestring.PubSub, Trajectory.topic(conversation.id))
    {:ok, _} = ModelCatalog.add("codex", "gpt-6-luna")

    # `@tag grant: false` starts with no grant; `@tag max_turns: N` sets its turns.
    if ctx[:grant] != false, do: grant!(repo, ctx[:max_turns] || 20)

    %{repo: repo, conversation: conversation, binding: %{session_id: "s1", repository: repo}}
  end

  defp grant!(repo, max_turns) do
    send(self(), {:mix_shell_input, :prompt, "y"})

    Grant.run(
      ~w(--models codex:gpt-6-luna --session s1 --max-dispatches 4 --max-parallel 2) ++
        ["--max-turns", to_string(max_turns)],
      %{
        shell: Mix.Shell.Process,
        with_repo: fn fun -> fun.(Repo) end,
        cwd: repo,
        service: fn -> :ok end,
        start_hint: "mix phx.server",
        interactive?: fn -> true end,
        env: fn "SHOESTRING_SESSION" -> "s1" end
      }
    )

    assert_receive {:mix_shell, :info, [json]}
    Jason.decode!(json)
  end

  defp grant, do: Shoestring.Grants.active("s1")

  defp git!(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  defp start_engine(conversation, opts \\ []) do
    opts =
      Keyword.merge([conversation_module: Fake.Conversation, tools_url: nil, poll_ms: nil], opts)

    start_supervised!(Supervisor.child_spec({Engine, {conversation, opts}}, restart: :temporary))
  end

  # The next committed event of `type`, skipping others.
  defp await(type) do
    assert_receive {:trajectory_event_committed, %{type: ^type} = event}, 5_000
    event
  end

  defp events(conversation) do
    {:ok, events} = Trajectory.replay(conversation.id)
    Enum.map(events, &{&1.type, &1.payload})
  end

  defp of_type(conversation, type),
    do: for({^type, payload} <- events(conversation), do: payload)

  defp say(engine, text), do: Engine.say(engine, Ecto.UUID.generate(), text)

  defp history(conversation) do
    {:ok, history} = Conversations.history(conversation)
    history
  end

  test "a message starts a turn whose reply, tools and end are recorded in order", ctx do
    engine = start_engine(ctx.conversation)

    assert :ok = say(engine, "SAY hello")
    assert %{payload: %{"status" => "completed"}} = await("conversation.turn.ended")

    assert [
             {"conversation.opened", %{"session_id" => "s1", "provider" => "claude"}},
             {"conversation.message.human", %{"text" => "SAY hello"}},
             # The intent is recorded before the coordinator is started.
             {"conversation.turn.requested", %{"message_ids" => [_], "inbox_ids" => []}},
             {"conversation.provider_session.bound",
              %{"provider_session_id" => "fake-conversation-session"}},
             {"conversation.message.coordinator", %{"item" => 0, "text" => "hello"}},
             {"conversation.turn.ended", %{"status" => "completed"}}
           ] = events(ctx.conversation)

    assert :ok = say(engine, "CALL dispatch")
    await("conversation.turn.ended")

    assert [_, %{tools: [%{tool: "dispatch", is_error: false}]}] =
             History.turns(history(ctx.conversation))

    assert %{state: :idle, pending_messages: 0} = Engine.status(engine)
  end

  test "a resent message id records and delivers nothing twice", ctx do
    engine = start_engine(ctx.conversation)
    id = Ecto.UUID.generate()

    assert :ok = Engine.say(engine, id, "SAY once")
    await("conversation.turn.ended")
    assert :ok = Engine.say(engine, id, "SAY once")
    _ = Engine.status(engine)

    assert [_] = of_type(ctx.conversation, "conversation.message.human")
    assert [_] = of_type(ctx.conversation, "conversation.turn.requested")
  end

  test "messages sent during a turn wait for it to end and go together in one turn", ctx do
    engine = start_engine(ctx.conversation)

    assert :ok = say(engine, "SLOW 60000 never")
    await("conversation.turn.requested")
    assert :ok = say(engine, "SAY two")
    assert :ok = say(engine, "SAY three")

    # Fake refuses a turn sent mid-turn, so an engine that sent one would
    # record it `unsent`.
    assert %{state: :in_turn, pending_messages: 2} = Engine.status(engine)
    assert [_] = of_type(ctx.conversation, "conversation.turn.requested")

    assert :ok = Engine.cancel_turn(engine)
    assert %{payload: %{"status" => "interrupted"}} = await("conversation.turn.ended")
    assert %{payload: %{"message_ids" => [_, _]}} = await("conversation.turn.requested")
    assert %{payload: %{"status" => "completed"}} = await("conversation.turn.ended")

    assert [%{"text" => "two\n\nSAY three"}] =
             of_type(ctx.conversation, "conversation.message.coordinator")

    assert {:error, :no_turn} = Engine.cancel_turn(engine)
  end

  test "an oversized or empty message is refused before anything is recorded", ctx do
    engine = start_engine(ctx.conversation)
    too_big = String.duplicate("x", Engine.max_message_bytes() + 1)

    assert {:error, :message_too_large} = say(engine, too_big)
    assert {:error, :empty_message} = say(engine, "  \n")
    assert of_type(ctx.conversation, "conversation.message.human") == []
    assert of_type(ctx.conversation, "conversation.turn.requested") == []
  end

  test "an oversized reply fails its turn and is not stored, even in part", ctx do
    engine = start_engine(ctx.conversation, max_reply_bytes: 10)

    assert :ok = say(engine, "SAY " <> String.duplicate("y", 11))

    assert %{payload: %{"status" => "failed", "reason" => "reply_too_large"}} =
             await("conversation.turn.ended")

    assert of_type(ctx.conversation, "conversation.message.coordinator") == []
  end

  test "visible text is stored redacted and the rest of it is kept", ctx do
    engine = start_engine(ctx.conversation)

    assert :ok = say(engine, "SAY the key is sk-live-abc123 keep this")
    await("conversation.turn.ended")

    assert [%{"text" => human}] = of_type(ctx.conversation, "conversation.message.human")
    assert [%{"text" => reply}] = of_type(ctx.conversation, "conversation.message.coordinator")

    for text <- [human, reply] do
      refute text =~ "sk-live-abc123"
      assert text =~ "[REDACTED]"
      assert text =~ "keep this"
    end
  end

  test "streamed text is one readable message and its secrets are redacted across chunks", ctx do
    engine = start_engine(ctx.conversation)
    assert :ok = say(engine, "SLOW 60000 never")
    stream_text(engine, ["keep this s", "k-synthetic123", " and this"])
    assert :ok = Engine.cancel_turn(engine)
    await("conversation.turn.ended")

    replies = of_type(ctx.conversation, "conversation.message.coordinator")
    text = Enum.map_join(replies, & &1["text"])
    refute text =~ "sk-synthetic123"
    assert text == "keep this [REDACTED] and this"
    assert length(replies) == 1
  end

  test "the reply cap is cumulative across chunks and tool-separated messages", ctx do
    engine = start_engine(ctx.conversation, max_reply_bytes: 10)
    assert :ok = say(engine, "SLOW 60000 never")
    stream_text(engine, ["abcdef"])
    %{adapter: adapter, turn: %{id: id}} = :sys.get_state(engine)

    send(
      engine,
      {:conversation_event, adapter,
       Shoestring.Harness.ConversationEvent.new(:tool_call, 101,
         turn_id: id,
         tool: "runs_list",
         tool_call_id: "call-1"
       )}
    )

    stream_text(engine, ["ghijkl"])
    _ = Engine.cancel_turn(engine)

    assert %{payload: %{"status" => "failed", "reason" => "reply_too_large"}} =
             await("conversation.turn.ended")

    assert [%{"text" => "abcdef"}] = of_type(ctx.conversation, "conversation.message.coordinator")
  end

  defp stream_text(engine, chunks) do
    %{adapter: adapter, turn: %{id: id}} = :sys.get_state(engine)

    for {text, ordinal} <- Enum.with_index(chunks, 100) do
      send(
        engine,
        {:conversation_event, adapter,
         Shoestring.Harness.ConversationEvent.new(:text, ordinal, turn_id: id, text: text)}
      )
    end

    _ = Engine.status(engine)
  end

  for {provider, module, cli} <- [
        {"codex", Shoestring.Harness.CodexAppServer.Conversation, "fake_codex_converse.py"},
        {"opencode", Shoestring.Harness.OpencodeAcp.Conversation, "fake_opencode_converse.py"}
      ] do
    @tag provider: provider, model: "opus", converse_module: module, cli: cli
    test "#{provider} transport chunks are redacted and displayed as one message", ctx do
      engine =
        start_engine(ctx.conversation,
          conversation_module: ctx.converse_module,
          conversation_opts: [executable: Path.expand("test/support/" <> ctx.cli)]
        )

      :ok = say(engine, "SPLIT keep sk-synthetic123 and readable text")
      await("conversation.turn.ended")
      replies = of_type(ctx.conversation, "conversation.message.coordinator")
      text = Enum.map_join(replies, & &1["text"])
      refute text =~ "sk-synthetic123"
      assert text == "keep [REDACTED] and readable text"
      assert length(replies) == 1
    end
  end

  test "redaction expansion also respects the retained visible text limit", ctx do
    engine = start_engine(ctx.conversation, max_context_bytes: 22)
    :ok = say(engine, "SLOW 60000 never")
    stream_text(engine, ["sk-a"])
    _ = Engine.cancel_turn(engine)

    assert %{payload: %{"status" => "failed", "reason" => "context_limit_reached"}} =
             await("conversation.turn.ended")

    assert of_type(ctx.conversation, "conversation.message.coordinator") == []
  end

  test "a new message cannot publish text after redaction exhausts context", ctx do
    engine = start_engine(ctx.conversation, max_context_bytes: 22)
    :ok = say(engine, "SLOW 60000 never")
    stream_text(engine, ["sk-a"])
    %{adapter: adapter, turn: %{id: id}} = :sys.get_state(engine)

    event =
      Shoestring.Harness.ConversationEvent.new(:text, 101, turn_id: id, text: "x")
      |> Map.merge(%{text_item: "next", text_complete: true})

    send(engine, {:conversation_event, adapter, event})
    _ = Engine.status(engine)
    _ = Engine.cancel_turn(engine)

    assert %{payload: %{"status" => "failed", "reason" => "context_limit_reached"}} =
             await("conversation.turn.ended")

    assert of_type(ctx.conversation, "conversation.message.coordinator") == []
  end

  test "pending input has an explicit bound and can be resent after the queue drains", ctx do
    engine = start_engine(ctx.conversation, max_input_bytes: 20)
    :ok = say(engine, "SLOW 60000 never")
    :ok = say(engine, "SAY 123456789")
    assert {:error, :pending_input_too_large} = say(engine, "SAY abcdefghi")
    assert %{pending_messages: 1} = Engine.status(engine)
    :ok = Engine.cancel_turn(engine)
    await("conversation.turn.ended")
    await("conversation.turn.ended")
    assert :ok = say(engine, "SAY abcdefghi")
    await("conversation.turn.ended")

    assert Enum.map(of_type(ctx.conversation, "conversation.message.coordinator"), & &1["text"]) ==
             ["123456789", "abcdefghi"]
  end

  test "retained visible context refuses new input consistently after restart", ctx do
    engine = start_engine(ctx.conversation, max_context_bytes: 20)
    :ok = say(engine, "SAY first")
    await("conversation.turn.ended")
    assert {:error, :context_limit_reached} = say(engine, "SAY second")
    :ok = stop_supervised({Engine, ctx.conversation.id})
    engine = start_engine(ctx.conversation, max_context_bytes: 20)
    assert {:error, :context_limit_reached} = say(engine, "SAY second")
    assert length(of_type(ctx.conversation, "conversation.turn.requested")) == 1
    assert Enum.map(history(ctx.conversation).messages, & &1.text) == ["SAY first", "first"]
  end

  test "a reply that exceeds retained context stops explicitly and leaves earlier text intact",
       ctx do
    engine = start_engine(ctx.conversation, max_context_bytes: 20)
    :ok = say(engine, "SLOW 60000 never")
    stream_text(engine, ["too large"])

    assert %{payload: %{"status" => "failed", "reason" => "context_limit_reached"}} =
             await("conversation.turn.ended")

    assert of_type(ctx.conversation, "conversation.message.coordinator") == []

    assert [%{"text" => "SLOW 60000 never"}] =
             of_type(ctx.conversation, "conversation.message.human")
  end

  @tag provider: "codex", model: "opus"
  test "scripted coordinator recalls context after restart and missing history makes no fresh call",
       ctx do
    store = ctx.repo <> "-provider-memory"

    opts = [
      conversation_module: Shoestring.Harness.CodexAppServer.Conversation,
      conversation_opts: [
        executable: Path.expand("test/support/fake_codex_converse.py"),
        env: [{"FAKE_CONVERSATION_MEMORY", store}]
      ]
    ]

    engine = start_engine(ctx.conversation, opts)
    :ok = say(engine, "REMEMBER Preserve signed zero.")
    await("conversation.turn.ended")
    session = Engine.status(engine).provider_session_id
    :ok = stop_supervised({Engine, ctx.conversation.id})
    engine = start_engine(ctx.conversation, opts)
    assert Engine.status(engine).provider_session_id == session
    assert grant().turns_used == 1
    :ok = say(engine, "RECALL")
    await("conversation.turn.ended")
    assert List.last(history(ctx.conversation).messages).text == "Preserve signed zero."
    :ok = stop_supervised({Engine, ctx.conversation.id})

    missing =
      Keyword.put(opts, :conversation_opts,
        executable: Path.expand("test/support/fake_codex_converse.py"),
        env: [{"FAKE_CONVERSATION_MEMORY", store <> "-missing"}]
      )

    engine = start_engine(ctx.conversation, missing)
    :ok = say(engine, "RECALL")
    assert %{payload: %{"status" => "unsent"}} = await("conversation.turn.ended")
    assert Engine.status(engine).provider_session_id == session
    assert grant().turns_used == 2
    assert length(of_type(ctx.conversation, "conversation.provider_session.bound")) == 1

    assert File.read!(Path.join(store, "calls.jsonl"))
           |> String.split("\n", trim: true)
           |> length() == 2

    refute File.exists?(Path.join(store <> "-missing", "calls.jsonl"))
  end

  test "a coordinator that cannot start leaves the turn unsent and sends nothing again", ctx do
    engine =
      start_engine(ctx.conversation, conversation_opts: [refuse_model: "claude-test-model"])

    assert :ok = say(engine, "SAY hello")

    assert %{payload: %{"status" => "unsent", "reason" => reason}} =
             await("conversation.turn.ended")

    assert is_binary(reason)

    assert %{state: :idle, pending_messages: 0} = Engine.status(engine)
    assert :ok = Engine.poll(engine)
    assert [_] = of_type(ctx.conversation, "conversation.turn.requested")
  end

  test "a coordinator process that exits mid-turn leaves the turn uncertain", ctx do
    engine = start_engine(ctx.conversation)

    assert :ok = say(engine, "SLOW 60000 never")
    await("conversation.turn.requested")
    %{adapter: adapter} = :sys.get_state(engine)
    Process.exit(adapter, :kill)

    assert %{payload: %{"status" => "uncertain", "reason" => "coordinator_exited"}} =
             await("conversation.turn.ended")

    assert %{state: :idle} = Engine.status(engine)
    assert [_] = of_type(ctx.conversation, "conversation.turn.requested")
  end

  test "a restart fences the open turn, makes no call, and resumes the provider session", ctx do
    engine = start_engine(ctx.conversation, conversation_opts: [session_id: "first-session"])
    assert :ok = say(engine, "SAY first")
    await("conversation.turn.ended")
    assert :ok = say(engine, "SLOW 60000 never")
    %{turn_id: open} = Engine.status(engine)

    ref = Process.monitor(engine)
    Process.exit(engine, :kill)
    assert_receive {:DOWN, ^ref, :process, ^engine, :killed}

    # A fresh session would report "fresh-session"; a resumed one keeps its id.
    engine = start_engine(ctx.conversation, conversation_opts: [session_id: "fresh-session"])

    assert %{
             payload: %{
               "turn_id" => ^open,
               "status" => "uncertain",
               "reason" => "service_restarted"
             }
           } =
             await("conversation.turn.ended")

    assert %{state: :idle, pending_messages: 0, provider_session_id: "first-session"} =
             Engine.status(engine)

    assert [_, _] = of_type(ctx.conversation, "conversation.turn.requested")
    assert %{adapter: nil} = :sys.get_state(engine)

    # The next turn resumes the recorded session rather than a fresh one.
    assert :ok = say(engine, "SAY again")
    await("conversation.turn.ended")

    assert [%{"provider_session_id" => "first-session"}] =
             of_type(ctx.conversation, "conversation.provider_session.bound")

    assert [
             %{kind: :human, text: "SAY first"},
             %{kind: :coordinator, text: "first"},
             %{kind: :human, text: "SLOW 60000 never"},
             %{kind: :human, text: "SAY again"},
             %{kind: :coordinator, text: "again"}
           ] = history(ctx.conversation).messages
  end

  test "stopping the engine mid-turn ends the turn uncertain", ctx do
    engine = start_engine(ctx.conversation)
    assert :ok = say(engine, "SLOW 60000 never")
    await("conversation.turn.requested")

    :ok = stop_supervised({Engine, ctx.conversation.id})

    assert %{payload: %{"status" => "uncertain", "reason" => "conversation_stopped"}} =
             await("conversation.turn.ended")
  end

  describe "grant and admission" do
    defp kinds(grant), do: Enum.map(Shoestring.Grants.events(grant.id), & &1.kind)

    @tag grant: false
    test "without a grant the message waits and says why once; a grant releases it", ctx do
      engine = start_engine(ctx.conversation)

      assert :ok = say(engine, "SAY hi")
      assert %{payload: %{"reason" => "no_grant"}} = await("conversation.turn.held")
      assert %{state: :idle, pending_messages: 1, hold: "no_grant"} = Engine.status(engine)

      assert :ok = Engine.poll(engine)
      assert [_] = of_type(ctx.conversation, "conversation.turn.held")
      assert of_type(ctx.conversation, "conversation.turn.requested") == []

      %{"grant_id" => grant_id} = grant!(ctx.repo, 20)
      assert :ok = Engine.poll(engine)

      # No usage reading here: the grant's turn is the confirmation.
      assert %{
               payload: %{
                 "grant_id" => ^grant_id,
                 "admission" => %{"result" => "admit", "reason_code" => "confirmed_" <> _}
               }
             } = await("conversation.turn.requested")

      assert %{payload: %{"status" => "completed"}} = await("conversation.turn.ended")
      assert %{turns_used: 1, max_turns: 20} = grant()
      assert %{hold: nil} = Engine.status(engine)
    end

    @tag max_turns: 1
    test "the turn cap holds the turn that would cross it until the grant is extended", ctx do
      engine = start_engine(ctx.conversation)

      assert :ok = say(engine, "SAY one")
      await("conversation.turn.ended")
      assert :ok = say(engine, "SAY two")

      assert %{payload: %{"reason" => "turns_exhausted"}} = await("conversation.turn.held")
      assert %{state: :idle, pending_messages: 1, hold: "turns_exhausted"} = Engine.status(engine)
      assert :ok = Engine.poll(engine)
      assert [_] = of_type(ctx.conversation, "conversation.turn.held")
      assert [_] = of_type(ctx.conversation, "conversation.turn.requested")

      {:ok, _} = Shoestring.Grants.extend(grant(), %{add_turns: 1}, "human:operator")
      assert :ok = Engine.poll(engine)
      await("conversation.turn.requested")
      await("conversation.turn.ended")

      assert [_, %{"text" => "two"}] =
               of_type(ctx.conversation, "conversation.message.coordinator")

      assert %{turns_used: 2, max_turns: 2} = grant()
    end

    test "a turn is charged once: a restart charges nothing again", ctx do
      engine = start_engine(ctx.conversation)
      assert :ok = say(engine, "SLOW 60000 never")
      await("conversation.turn.requested")

      ref = Process.monitor(engine)
      Process.exit(engine, :kill)
      assert_receive {:DOWN, ^ref, :process, ^engine, :killed}

      engine = start_engine(ctx.conversation)
      assert %{payload: %{"status" => "uncertain"}} = await("conversation.turn.ended")
      assert :ok = Engine.poll(engine)

      assert %{turns_used: 1} = grant()
      assert kinds(grant()) == ["created", "turn_used"]
    end

    test "a turn that never reached the coordinator is refunded", ctx do
      engine =
        start_engine(ctx.conversation, conversation_opts: [refuse_model: "claude-test-model"])

      assert :ok = say(engine, "SAY hello")
      assert %{payload: %{"status" => "unsent"}} = await("conversation.turn.ended")

      assert %{turns_used: 0} = grant()
      assert kinds(grant()) == ["created", "turn_used", "turn_refunded"]
    end

    test "a breached reserve defers the turn, charging nothing and starting nothing", ctx do
      now = DateTime.utc_now()
      resets = now |> DateTime.add(3_600) |> DateTime.to_unix()

      {:ok, reading} =
        Shoestring.Harness.Capacity.normalize(
          :claude,
          :headless_stream_json,
          %{
            "type" => "rate_limit_event",
            "rate_limit_info" => %{
              "status" => "allowed",
              "unifiedWindows" => %{
                "five_hour" => %{
                  "utilization" => 0.95,
                  "resetsAt" => resets,
                  "status" => "allowed"
                },
                "seven_day" => %{
                  "utilization" => 0.1,
                  "resetsAt" => resets,
                  "status" => "allowed"
                }
              }
            }
          },
          version: "2.1.310",
          now: now,
          captured_at: now,
          adapter_id: "claude_headless_stream_json",
          scope: "subscription"
        )

      {:ok, _, _} = Shoestring.Harness.Observatory.ingest(reading, now: now)
      engine = start_engine(ctx.conversation)

      assert :ok = say(engine, "SAY hi")
      assert %{payload: %{"defer_until" => until}} = await("conversation.turn.held")
      {:ok, until, _} = DateTime.from_iso8601(until)
      assert DateTime.to_unix(until) == resets

      assert of_type(ctx.conversation, "conversation.turn.requested") == []
      assert %{turns_used: 0} = grant()
      assert %{adapter: nil} = :sys.get_state(engine)
    end
  end

  describe "inbox and wake" do
    defp dispatch!(binding, title, worker \\ "codex:gpt-6-luna") do
      args = %{
        "purpose" => "implement",
        "worker" => worker,
        "title" => title,
        "brief" => @brief,
        "files" => ["calc.py"]
      }

      {:ok, %{"dispatch_id" => id}} = Tools.call("dispatch", args, binding)
      id
    end

    defp cancel!(binding, id),
      do: {:ok, _} = Tools.call("runs_cancel", %{"dispatch" => id, "reason" => "test"}, binding)

    test "a dispatch settling while idle wakes the coordinator with one turn", ctx do
      engine = start_engine(ctx.conversation)
      id = dispatch!(ctx.binding, "Make add return the sum")

      assert :ok = Engine.poll(engine)
      assert of_type(ctx.conversation, "conversation.inbox.recorded") == []

      cancel!(ctx.binding, id)
      assert :ok = Engine.poll(engine)

      assert %{payload: %{"dispatch_id" => ^id, "state" => "cancelled", "entry_id" => entry}} =
               await("conversation.inbox.recorded")

      assert %{payload: %{"message_ids" => [], "inbox_ids" => [^entry]}} =
               await("conversation.turn.requested")

      await("conversation.turn.ended")

      # Settled once: another poll records and wakes nothing.
      assert :ok = Engine.poll(engine)
      assert [_] = of_type(ctx.conversation, "conversation.inbox.recorded")
      assert [_] = of_type(ctx.conversation, "conversation.turn.requested")

      assert {:ok, [%{"dispatch_id" => ^id, "state" => "cancelled", "delivered" => true}]} =
               Tools.call("read_inbox", %{}, ctx.binding)
    end

    @tag grant: false
    test "a hold the grant pre-approved wakes nothing; one with none left wakes the coordinator",
         ctx do
      {:ok, _} = ModelCatalog.add("opencode", "opencode/fixture-free")
      {root, 0} = System.cmd("git", ["-C", ctx.repo, "rev-parse", "--show-toplevel"])

      {:ok, _} =
        Shoestring.Grants.create(
          %{
            session_id: "s1",
            repository_root: String.trim(root),
            models: ["opencode:opencode/fixture-free"],
            purposes: ["implement"],
            max_dispatches: 2,
            max_parallel: 2,
            max_total_seconds: 7_200,
            max_dispatch_seconds: 3_600,
            unread_usage: 1,
            max_turns: 20
          },
          "human:operator"
        )

      engine = start_engine(ctx.conversation)
      first = dispatch!(ctx.binding, "First", "opencode:opencode/fixture-free")
      second = dispatch!(ctx.binding, "Second", "opencode:opencode/fixture-free")

      # opencode's remaining usage is never readable, so admission asks.
      hold! = fn id ->
        dispatch = Repo.get!(Shoestring.Dispatches.Dispatch, id)

        {:ok, %{execution: execution}} =
          Shoestring.Cobbler.ExecutionControl.status(dispatch.goal_id)

        task = %{"id" => "dispatch", "execution" => %{"max_duration_seconds" => 1800}}

        assert {:error, {:execution_admission_blocked, _}} =
                 Shoestring.Cobbler.ExecutionAdmission.admit(dispatch.goal_id, execution, task, 1)
      end

      hold!.(first)
      assert :ok = Engine.poll(engine)
      assert grant().unread_usage_used == 1
      assert of_type(ctx.conversation, "conversation.inbox.recorded") == []
      assert of_type(ctx.conversation, "conversation.turn.requested") == []

      hold!.(second)
      assert :ok = Engine.poll(engine)

      assert %{payload: %{"dispatch_id" => ^second, "state" => "held"}} =
               await("conversation.inbox.recorded")

      await("conversation.turn.requested")
      assert [_] = of_type(ctx.conversation, "conversation.inbox.recorded")
    end

    test "a dispatch settling during a turn waits for it; two settling go in one turn", ctx do
      engine = start_engine(ctx.conversation)
      first = dispatch!(ctx.binding, "First")
      second = dispatch!(ctx.binding, "Second")

      assert :ok = say(engine, "SLOW 60000 never")
      await("conversation.turn.requested")
      cancel!(ctx.binding, first)
      cancel!(ctx.binding, second)
      assert :ok = Engine.poll(engine)

      assert %{state: :in_turn, pending_inbox: 2} = Engine.status(engine)
      assert [_] = of_type(ctx.conversation, "conversation.turn.requested")

      assert {:ok, [%{"delivered" => false}, %{"delivered" => false}]} =
               Tools.call("read_inbox", %{}, ctx.binding)

      assert :ok = Engine.cancel_turn(engine)
      assert %{payload: %{"status" => "interrupted"}} = await("conversation.turn.ended")

      assert %{payload: %{"inbox_ids" => [_, _], "message_ids" => []}} =
               await("conversation.turn.requested")

      await("conversation.turn.ended")
    end

    test "read_inbox is empty for a session without a conversation", ctx do
      assert {:ok, []} = Tools.call("read_inbox", %{}, %{ctx.binding | session_id: "other"})
    end

    test "an interrupted dispatch creation is starting, then reports a failed start", ctx do
      engine = start_engine(ctx.conversation)
      id = dispatch!(ctx.binding, "Interrupted creation")
      dispatch = Repo.get!(Shoestring.Dispatches.Dispatch, id)

      dispatch =
        dispatch |> Ecto.Changeset.change(state: "creating", goal_id: nil) |> Repo.update!()

      assert :ok = Engine.poll(engine)
      assert of_type(ctx.conversation, "conversation.inbox.recorded") == []
      dispatch |> Ecto.Changeset.change(state: "failed", error: "start_failed") |> Repo.update!()
      assert :ok = Engine.poll(engine)

      assert %{payload: %{"dispatch_id" => ^id, "state" => "failed_to_start"}} =
               await("conversation.inbox.recorded")

      await("conversation.turn.ended")
      :ok = Engine.poll(engine)
      assert length(of_type(ctx.conversation, "conversation.inbox.recorded")) == 1
    end

    @tag grant: false
    test "a later hold on the same dispatch wakes once and remains deduplicated after restart",
         ctx do
      {:ok, _} = ModelCatalog.add("opencode", "opencode/fixture-free")
      {:ok, facts} = Shoestring.Cobbler.Intake.repository(ctx.repo)

      {:ok, _} =
        Shoestring.Grants.create(
          %{
            session_id: "s1",
            repository_root: facts.root,
            models: ["opencode:opencode/fixture-free"],
            purposes: ["implement"],
            max_dispatches: 2,
            max_parallel: 2,
            max_total_seconds: 7200,
            max_dispatch_seconds: 3600,
            unread_usage: 0,
            max_turns: 20
          },
          "human:operator"
        )

      id = dispatch!(ctx.binding, "Two holds", "opencode:opencode/fixture-free")
      dispatch = Repo.get!(Shoestring.Dispatches.Dispatch, id)

      {:ok, %{execution: execution}} =
        Shoestring.Cobbler.ExecutionControl.status(dispatch.goal_id)

      task = %{"id" => "dispatch", "execution" => %{"max_duration_seconds" => 1800}}

      hold! = fn ->
        assert {:error, {:execution_admission_blocked, _}} =
                 Shoestring.Cobbler.ExecutionAdmission.admit(dispatch.goal_id, execution, task, 1)
      end

      hold!.()
      # A prior release observed and delivered the first hold without a
      # settlement reference. Upgrading must not wake or charge it again.
      entry_id = Ecto.UUID.generate()
      turn_id = Ecto.UUID.generate()

      for {type, payload} <- [
            {"conversation.inbox.recorded",
             %{"entry_id" => entry_id, "dispatch_id" => id, "state" => "held"}},
            {"conversation.turn.requested",
             %{"turn_id" => turn_id, "message_ids" => [], "inbox_ids" => [entry_id]}},
            {"conversation.turn.ended", %{"turn_id" => turn_id, "status" => "completed"}}
          ] do
        assert {:ok, _} =
                 Trajectory.append(ctx.conversation.id, %{
                   "type" => type,
                   "schema_version" => 1,
                   "actor" => "conversation",
                   "idempotency_key" => "legacy:#{type}",
                   "payload" => payload
                 })
      end

      await("conversation.turn.ended")

      assert {:ok, _} =
               Shoestring.Grants.use_turn(grant(), %{
                 "turn_id" => turn_id,
                 "conversation_id" => ctx.conversation.id
               })

      engine = start_engine(ctx.conversation)
      :ok = Engine.poll(engine)
      assert :ok = Engine.poll(engine)
      assert length(of_type(ctx.conversation, "conversation.inbox.recorded")) == 1
      assert grant().turns_used == 1

      assert {:ok, _} =
               Shoestring.Cobbler.ExecutionControl.confirm_capacity(dispatch.goal_id, %{
                 execution_id: execution.execution_id,
                 task_id: "dispatch",
                 attempt: 1,
                 scope: "subscription",
                 command_id: Ecto.UUID.generate(),
                 requested_by: "human:operator"
               })

      assert {:ok, _} =
               Shoestring.Cobbler.ExecutionAdmission.admit(dispatch.goal_id, execution, task, 1)

      :ok = Engine.poll(engine)
      hold!.()
      :ok = Engine.poll(engine)
      assert length(of_type(ctx.conversation, "conversation.inbox.recorded")) == 2
      await("conversation.turn.ended")

      :ok = stop_supervised({Engine, ctx.conversation.id})
      engine = start_engine(ctx.conversation)
      :ok = Engine.poll(engine)
      assert length(of_type(ctx.conversation, "conversation.inbox.recorded")) == 2
      assert length(of_type(ctx.conversation, "conversation.turn.requested")) == 2
      assert grant().turns_used == 2
    end
  end

  describe "open" do
    test "returns the session's conversation and refuses another coordinator", ctx do
      attrs = %{
        session_id: "s1",
        provider: "claude",
        model: "claude-test-model",
        effort: nil,
        repository_root: ctx.repo
      }

      assert {:ok, %{id: id}} = Conversations.open(attrs)
      assert id == ctx.conversation.id
      assert [_] = of_type(ctx.conversation, "conversation.opened")

      assert {:error, :conversation_has_another_coordinator} =
               Conversations.open(%{attrs | model: "claude-other"})

      assert {:error, {:cannot_converse, "unknown-cli"}} =
               Conversations.open(%{attrs | session_id: "s2", provider: "unknown-cli"})

      assert Conversations.get("s2") == nil

      assert {:error, :invalid_session} =
               Conversations.open(%{attrs | session_id: "../elsewhere"})
    end
  end
end
