defmodule Shoestring.Conversations.HandoffTest do
  @moduledoc """
  Handing a session's conversation off to a fresh one (iteration 16
  package A), against `Shoestring.Harness.Fake.Conversation`, a real
  temporary Git repository and a grant made the way a person makes one: no
  service, provider or network. Assertions read trajectory events, rows and
  the turn text the fake coordinator was given.
  """
  use Shoestring.DataCase, async: false

  alias Shoestring.{Conversations, Dispatches, ModelCatalog, Repo, Trajectory}
  alias Shoestring.CLI.Commands.Grant
  alias Shoestring.Conversations.{Conversation, Engine, Handoff, History}
  alias Shoestring.Coordinator.Tools
  alias Shoestring.Harness.Fake

  @brief "IMPLEMENT - make add() return the sum\nContract: test/test_calc.py passes.\n"
  @note "Requirement: order ids are ORD- plus 8 digits; the person said never 6."

  setup ctx do
    repo = Path.join(System.tmp_dir!(), "shoestring-handoff-#{Ecto.UUID.generate()}")
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
        provider: "claude",
        model: "claude-test-model",
        effort: nil,
        repository_root: repo
      })

    Phoenix.PubSub.subscribe(Shoestring.PubSub, Trajectory.topic(conversation.id))
    {:ok, _} = ModelCatalog.add("codex", "gpt-6-luna")
    grant!(repo, ctx[:max_turns] || 20)

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

    assert_receive {:mix_shell, :info, _json}
  end

  defp git!(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  # The handoff instruction gets `note`; any other turn runs its own text.
  defp script(note) do
    fn text -> if text =~ "Reply with only the handoff note", do: note, else: text end
  end

  defp start_engine(conversation, opts \\ []) do
    opts =
      Keyword.merge(
        [
          conversation_module: Fake.Conversation,
          conversation_opts: [script: script("SAY " <> @note), observer: self()],
          tools_url: nil,
          poll_ms: nil,
          start_successor: false
        ],
        opts
      )

    engine =
      start_supervised!(
        Supervisor.child_spec({Engine, {conversation, opts}},
          id: conversation.id,
          restart: :temporary
        )
      )

    Process.put({:monitor, engine}, Process.monitor(engine))
    engine
  end

  # A whole turn, so no event of it is left to a later `await`.
  defp turn!(engine, text) do
    assert :ok = say(engine, text)
    await("conversation.turn.requested")
    await("conversation.turn.ended")
  end

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

  defp dispatch!(binding, title) do
    args = %{
      "purpose" => "implement",
      "worker" => "codex:gpt-6-luna",
      "title" => title,
      "brief" => @brief,
      "files" => ["calc.py"]
    }

    {:ok, %{"dispatch_id" => id}} = Tools.call("dispatch", args, binding)
    id
  end

  defp cancel!(binding, id),
    do: {:ok, _} = Tools.call("runs_cancel", %{"dispatch" => id, "reason" => "test"}, binding)

  defp handed_off!(engine) do
    ref = Process.get({:monitor, engine})
    assert %{payload: %{"successor_id" => successor_id}} = await("conversation.handed_off")
    assert_receive {:DOWN, ^ref, :process, ^engine, :normal}, 5_000
    successor = Repo.get!(Conversation, successor_id)
    Phoenix.PubSub.subscribe(Shoestring.PubSub, Trajectory.topic(successor.id))
    successor
  end

  test "the note turn delivers only the instruction; the successor reads the note and facts with the next message",
       ctx do
    engine = start_engine(ctx.conversation)
    turn!(engine, "SAY noted")
    assert_receive {:fake_conversation_turn, "SAY noted"}

    assert :ok = Engine.handoff(engine)
    assert %{payload: %{"handoff_id" => handoff_id}} = await("conversation.handoff.requested")

    assert %{payload: %{"message_ids" => [^handoff_id], "inbox_ids" => []}} =
             await("conversation.turn.requested")

    instruction = Handoff.instruction()
    assert_receive {:fake_conversation_turn, ^instruction}

    assert %{payload: %{"note" => @note, "note_status" => "written", "carried" => []}} =
             await("conversation.handoff.prepared")

    successor = handed_off!(engine)

    # The session's current conversation is the successor; the old one is
    # handed off and its engine cannot be started again.
    assert successor.id == handoff_id
    assert successor.predecessor_id == ctx.conversation.id
    assert Conversations.get("s1").id == successor.id
    assert %{handed_off_at: %DateTime{}} = Repo.get!(Conversation, ctx.conversation.id)
    assert {:error, :handed_off} = Conversations.start(ctx.conversation)
    assert {:error, _} = start_supervised({Engine, {ctx.conversation, [poll_ms: nil]}})

    # The grant is the session's, unchanged: two turns charged in all.
    assert %{turns_used: 2} = Shoestring.Grants.active("s1")

    next = start_engine(successor)

    assert [{"conversation.opened", _}, {"conversation.handoff.received", received}] =
             events(successor)

    assert received["predecessor_id"] == ctx.conversation.id
    assert received["note"] == @note

    # The handoff alone starts no turn, and the coordinator starts fresh.
    assert :ok = Engine.poll(next)
    assert of_type(successor, "conversation.turn.requested") == []
    assert history(successor).provider_session_id == nil

    assert :ok = say(next, "SAY carry on")
    predecessor_id = ctx.conversation.id

    assert %{payload: %{"message_ids" => [^predecessor_id, _message]}} =
             await("conversation.turn.requested")

    assert_receive {:fake_conversation_turn, text}
    assert text =~ "continues coordinator conversation #{predecessor_id}"
    assert text =~ "Facts from Shoestring's records"
    assert text =~ @note
    assert String.ends_with?(text, "SAY carry on")
    assert %{turns_used: 3} = Shoestring.Grants.active("s1")
  end

  test "the facts are Shoestring's records: the grant's room and every dispatch of the session",
       ctx do
    first = dispatch!(ctx.binding, "First task")
    second = dispatch!(ctx.binding, "Second task")
    cancel!(ctx.binding, first)

    facts = Handoff.facts(ctx.conversation, history(ctx.conversation), DateTime.utc_now())
    grant = Shoestring.Grants.active("s1")
    room = Dispatches.room(grant)

    assert facts =~ "Grant #{String.slice(grant.id, 0, 8)}: 20 of 20 coordinator turns left"

    assert facts =~
             "#{room["attempts"]["limit"] - room["attempts"]["used"]} of #{room["attempts"]["limit"]} dispatch attempts left"

    assert facts =~ "Dispatches in this session, newest first (2):"

    for dispatch <- Dispatches.list("s1") do
      assert facts =~
               "- #{dispatch.id} implement \"#{dispatch.title}\" on codex:gpt-6-luna: " <>
                 Dispatches.state(dispatch)
    end

    # Newest first.
    {at_second, _} = :binary.match(facts, second)
    {at_first, _} = :binary.match(facts, first)
    assert at_second < at_first
  end

  @tag :tmp_dir
  test "a dispatch announced before the handoff is not announced again; one never delivered is",
       ctx do
    engine =
      start_engine(ctx.conversation,
        conversation_opts: [script: script("SLOW 60000 never"), observer: self()]
      )

    delivered = dispatch!(ctx.binding, "Delivered")
    undelivered = dispatch!(ctx.binding, "Undelivered")
    cancel!(ctx.binding, delivered)
    assert :ok = Engine.poll(engine)
    assert %{payload: %{"dispatch_id" => ^delivered}} = await("conversation.inbox.recorded")
    assert %{payload: %{"inbox_ids" => [_]}} = await("conversation.turn.requested")
    assert %{payload: %{"status" => "completed"}} = await("conversation.turn.ended")

    # During the note turn: an inbox entry and a message, both undelivered.
    assert :ok = Engine.handoff(engine)
    await("conversation.turn.requested")
    cancel!(ctx.binding, undelivered)
    assert :ok = Engine.poll(engine)
    assert %{payload: %{"dispatch_id" => ^undelivered}} = await("conversation.inbox.recorded")
    assert :ok = say(engine, "SAY carried")
    assert {:error, :turn_running} = Engine.handoff(engine, note: false)

    assert :ok = Engine.cancel_turn(engine)

    assert %{payload: %{"note_status" => "turn_interrupted"} = prepared} =
             await("conversation.handoff.prepared")

    refute Map.has_key?(prepared, "note")
    assert [%{"text" => "SAY carried"}] = prepared["carried"]
    assert [%{"dispatch_id" => ^delivered, "state" => "cancelled"}] = prepared["known"]

    successor = handed_off!(engine)
    next = start_engine(successor)

    # At its first poll the carried message starts the first turn, with the
    # handoff; the undelivered settlement is announced again, the delivered
    # one is not.
    assert :ok = Engine.poll(next)

    assert %{payload: %{"message_ids" => [_handoff, _carried]}} =
             await("conversation.turn.requested")

    await("conversation.turn.ended")

    assert [%{"dispatch_id" => ^undelivered, "state" => "cancelled"}] =
             of_type(successor, "conversation.inbox.recorded")
  end

  test "a conversation at its text limit still gets its note", ctx do
    engine = start_engine(ctx.conversation, max_context_bytes: 20)
    turn!(engine, "SAY 12345678")
    assert {:error, :context_limit_reached} = say(engine, "SAY more")

    assert :ok = Engine.handoff(engine)

    assert %{payload: %{"note_status" => "written", "note" => @note}} =
             await("conversation.handoff.prepared")

    handed_off!(engine)
  end

  @tag max_turns: 1
  test "a held note turn can be skipped: the facts carry over alone and nothing more is charged",
       ctx do
    engine = start_engine(ctx.conversation)
    turn!(engine, "SAY hi")

    assert :ok = Engine.handoff(engine)
    assert %{payload: %{"reason" => "turns_exhausted"}} = await("conversation.turn.held")
    assert {:error, :handoff_in_progress} = Engine.handoff(engine)

    assert :ok = Engine.handoff(engine, note: false)

    assert %{payload: %{"note_status" => "skipped:turns_exhausted"} = prepared} =
             await("conversation.handoff.prepared")

    refute Map.has_key?(prepared, "note")
    successor = handed_off!(engine)
    assert %{turns_used: 1} = Shoestring.Grants.active("s1")

    [{_, _}, {"conversation.handoff.received", received}] = events(successor)
    assert Handoff.text(received) =~ "wrote no note (skipped:turns_exhausted)"
  end

  @tag max_turns: 1
  test "a held note turn starts once the grant allows it, still with only the instruction",
       ctx do
    engine = start_engine(ctx.conversation)
    turn!(engine, "SAY hi")
    assert :ok = say(engine, "SAY waiting")
    assert %{payload: %{"reason" => "turns_exhausted"}} = await("conversation.turn.held")
    assert :ok = Engine.handoff(engine)
    await("conversation.handoff.requested")

    {:ok, _} =
      Shoestring.Grants.extend(Shoestring.Grants.active("s1"), %{add_turns: 1}, "human:test")

    assert :ok = Engine.poll(engine)
    %{handoff: %{id: handoff_id}} = history(ctx.conversation)
    instruction = Handoff.instruction()

    assert %{payload: %{"message_ids" => [^handoff_id]}} = await("conversation.turn.requested")
    assert_receive {:fake_conversation_turn, ^instruction}

    assert %{payload: %{"note_status" => "written", "carried" => [%{"text" => "SAY waiting"}]}} =
             await("conversation.handoff.prepared")

    handed_off!(engine)
  end

  test "a handoff from a conversation that never delivered its own handoff passes it on",
       ctx do
    engine = start_engine(ctx.conversation)
    assert :ok = Engine.handoff(engine, note: false)
    await("conversation.handoff.prepared")
    successor = handed_off!(engine)

    next = start_engine(successor)
    assert :ok = Engine.handoff(next)
    predecessor_id = ctx.conversation.id
    %{handoff: %{id: handoff_id}} = history(successor)

    assert %{payload: %{"message_ids" => [^predecessor_id, ^handoff_id]}} =
             await("conversation.turn.requested")

    assert_receive {:fake_conversation_turn, text}
    assert text =~ "continues coordinator conversation #{predecessor_id}"
    assert String.ends_with?(text, Handoff.instruction())

    assert %{payload: %{"note_status" => "written"}} = await("conversation.handoff.prepared")
    last = handed_off!(next)
    assert last.predecessor_id == successor.id
    assert Conversations.get("s1").id == last.id
  end

  test "a handoff without a note runs no turn", ctx do
    engine = start_engine(ctx.conversation)
    assert :ok = Engine.handoff(engine, note: false)

    assert %{payload: %{"note_status" => "not_requested"}} =
             await("conversation.handoff.prepared")

    handed_off!(engine)
    assert of_type(ctx.conversation, "conversation.turn.requested") == []
    assert %{turns_used: 0} = Shoestring.Grants.active("s1")
  end

  describe "restart" do
    test "with the note turn open: it ends uncertain, is not sent again, and the handoff completes",
         ctx do
      opts = [conversation_opts: [script: script("SLOW 60000 never"), observer: self()]]
      engine = start_engine(ctx.conversation, opts)
      assert :ok = Engine.handoff(engine)
      await("conversation.turn.requested")
      assert_receive {:fake_conversation_turn, _instruction}

      :ok = stop_supervised(ctx.conversation.id)
      assert %{payload: %{"status" => "uncertain"}} = await("conversation.turn.ended")

      engine = start_engine(ctx.conversation, opts)

      assert %{payload: %{"note_status" => "turn_uncertain"}} =
               await("conversation.handoff.prepared")

      handed_off!(engine)
      assert [_] = of_type(ctx.conversation, "conversation.turn.requested")
      refute_received {:fake_conversation_turn, _}
    end

    test "after it was prepared: the switch happens once, and asking again changes nothing",
         ctx do
      successor_id = Ecto.UUID.generate()
      history = history(ctx.conversation)

      append!(ctx.conversation, "conversation.handoff.requested", "handoff-requested", %{
        "handoff_id" => successor_id,
        "note" => false
      })

      history = History.apply_event(history, last_event(ctx.conversation))
      prepared = Handoff.prepare(ctx.conversation, history, successor_id, DateTime.utc_now())
      append!(ctx.conversation, "conversation.handoff.prepared", "handoff-prepared", prepared)

      engine = start_engine(ctx.conversation)
      successor = handed_off!(engine)
      assert successor.id == successor_id

      assert {:ok, %{id: ^successor_id}} = Conversations.hand_off(ctx.conversation, prepared)
      assert [_] = of_type(ctx.conversation, "conversation.handed_off")
      assert [_] = of_type(successor, "conversation.handoff.received")

      assert 2 ==
               Repo.aggregate(
                 from(c in Conversation, where: c.session_id == "s1"),
                 :count
               )
    end
  end

  defp append!(conversation, type, key, payload) do
    {:ok, _} =
      Trajectory.append(conversation.id, %{
        "type" => type,
        "schema_version" => 1,
        "actor" => "conversation",
        "idempotency_key" => key,
        "payload" => payload
      })
  end

  defp last_event(conversation) do
    {:ok, events} = Trajectory.replay(conversation.id)
    List.last(events)
  end
end
