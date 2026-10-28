defmodule ShoestringWeb.ChatChannelTest do
  @moduledoc """
  The chat socket and channel with `Shoestring.Harness.Fake.Conversation`
  as the coordinator, a real temporary Git repository, a grant and Oban in
  manual testing mode: no provider, network or listener.
  """
  use Shoestring.DataCase, async: false

  import Phoenix.ChannelTest

  alias Shoestring.{Conversations, Grants, ModelCatalog, Repo, Trajectory}
  alias Shoestring.Conversations.{ChatToken, Engine, Resume}
  alias Shoestring.Coordinator.Tools
  alias Shoestring.Harness.Fake
  alias ShoestringWeb.{ChatChannel, ChatSocket}

  @endpoint ShoestringWeb.Endpoint
  @brief "IMPLEMENT - make add() return the sum\nContract: test/test_calc.py passes.\n"
  @engine_opts [conversation_module: Fake.Conversation, tools_url: nil, poll_ms: nil]

  setup do
    session = "chat-#{System.unique_integer([:positive])}"
    repo = Path.join(System.tmp_dir!(), "shoestring-chat-#{Ecto.UUID.generate()}")
    File.mkdir_p!(Path.join(repo, "test"))
    on_exit(fn -> File.rm_rf!(repo) end)
    on_exit(fn -> File.rm_rf!(Path.dirname(ChatToken.path(session))) end)
    File.write!(Path.join(repo, "calc.py"), "def add(a, b):\n    raise NotImplementedError\n")
    File.write!(Path.join(repo, "test/test_calc.py"), "import unittest\n")
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["add", "."])
    git!(repo, ["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qm", "base"])
    # A grant names the repository's canonical root.
    {root, 0} = System.cmd("git", ["-C", repo, "rev-parse", "--show-toplevel"])
    repo = String.trim(root)

    {:ok, _} = ModelCatalog.add("codex", "gpt-6-luna")
    {:ok, grant} = grant(session, repo)
    {:ok, conversation} = open(session, repo)
    {:ok, token} = ChatToken.ensure(session)

    start_supervised!(
      Supervisor.child_spec({Engine, {conversation, @engine_opts}}, restart: :temporary)
    )

    %{
      session: session,
      repo: repo,
      grant: grant,
      conversation: conversation,
      token: token,
      socket: socket(ChatSocket, nil, %{session_id: session})
    }
  end

  defp git!(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  defp grant(session, repo) do
    Grants.create(
      %{
        session_id: session,
        repository_root: repo,
        models: ["codex:gpt-6-luna"],
        purposes: Grants.purposes(),
        max_dispatches: 4,
        max_parallel: 2,
        max_total_seconds: 4 * 3600,
        max_dispatch_seconds: 3600,
        unread_usage: 0,
        max_turns: 10
      },
      "human:operator"
    )
  end

  defp open(session, repo) do
    Conversations.open(%{
      session_id: session,
      provider: "claude",
      model: "claude-test-model",
      effort: nil,
      repository_root: repo
    })
  end

  defp info(overrides \\ %{}) do
    Map.merge(
      %{
        peer_data: %{address: {127, 0, 0, 1}},
        uri: URI.parse("http://localhost:4002/chat/socket")
      },
      overrides
    )
  end

  defp join!(ctx, params \\ %{}) do
    {:ok, _reply, socket} =
      subscribe_and_join(ctx.socket, ChatChannel, "conversation:#{ctx.session}", params)

    socket
  end

  # Pushed events until one of `type` arrives, in order.
  defp events_until(type, seen \\ []) do
    assert_push "events", %{"events" => events}, 5_000
    seen = seen ++ events

    if Enum.any?(events, &(&1["type"] == type)), do: seen, else: events_until(type, seen)
  end

  defp say(socket, text, id \\ Ecto.UUID.generate()),
    do: push(socket, "say", %{"message_id" => id, "text" => text})

  test "a socket needs loopback, a local host and its conversation's token", ctx do
    params = %{"session" => ctx.session, "token" => ctx.token}

    assert {:ok, socket} = connect(ChatSocket, params, connect_info: info())
    assert socket.assigns.session_id == ctx.session

    assert :error =
             connect(ChatSocket, params,
               connect_info: info(%{peer_data: %{address: {192, 0, 2, 1}}})
             )

    assert :error =
             connect(ChatSocket, params,
               connect_info: info(%{uri: URI.parse("http://rebound.example/chat/socket")})
             )

    assert :error = connect(ChatSocket, %{params | "token" => "x"}, connect_info: info())
    assert :error = connect(ChatSocket, %{"token" => ctx.token}, connect_info: info())

    # Another session's token opens nothing here.
    {:ok, other} = ChatToken.ensure("chat-other-#{System.unique_integer([:positive])}")
    assert :error = connect(ChatSocket, %{params | "token" => other}, connect_info: info())
  end

  test "a socket joins only its own session's conversation", ctx do
    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(ctx.socket, ChatChannel, "conversation:someone-else", %{})

    assert {:error, %{reason: "invalid_after"}} =
             subscribe_and_join(ctx.socket, ChatChannel, "conversation:#{ctx.session}", %{
               "after" => -1
             })

    lonely = socket(ChatSocket, nil, %{session_id: "chat-none"})

    assert {:error, %{reason: "no_conversation"}} =
             subscribe_and_join(lonely, ChatChannel, "conversation:chat-none", %{})
  end

  test "joining pushes the stored events, then live ones, then resumes after `after` with no repeats",
       ctx do
    socket = join!(ctx)

    assert [%{"type" => "conversation.opened", "sequence" => 1}] =
             events_until("conversation.opened")

    assert_push "state", %{"engine" => %{"state" => "idle"}, "grant" => %{"turns" => _}}

    ref = say(socket, "SAY hello")
    assert_reply ref, :ok

    seen = events_until("conversation.turn.ended")
    sequences = Enum.map(seen, & &1["sequence"])
    assert sequences == Enum.sort(Enum.uniq(sequences))
    assert Enum.any?(seen, &(&1["payload"]["text"] == "hello"))
    last = List.last(sequences)

    Process.unlink(socket.channel_pid)
    :ok = close(socket)

    # More happens with no client attached.
    Phoenix.PubSub.subscribe(Shoestring.PubSub, Trajectory.topic(ctx.conversation.id))
    :ok = Engine.say(Engine.via(ctx.conversation.id), Ecto.UUID.generate(), "SAY again")
    assert_receive {:trajectory_event_committed, %{type: "conversation.turn.ended"}}, 5_000
    {:ok, events} = Trajectory.replay(ctx.conversation.id)
    assert Enum.any?(events, &(&1.type == "conversation.turn.ended" and &1.sequence > last))

    join!(ctx, %{"after" => last})
    resumed = events_until("conversation.turn.ended")
    assert hd(resumed)["sequence"] == last + 1

    assert Enum.map(resumed, & &1["sequence"]) ==
             Enum.map(Enum.filter(events, &(&1.sequence > last)), & &1.sequence)
  end

  test "say and cancel_turn reach the engine and refuse what it refuses", ctx do
    socket = join!(ctx)
    events_until("conversation.opened")

    ref = say(socket, "SLOW 60000 never")
    assert_reply ref, :ok
    events_until("conversation.turn.requested")

    ref = push(socket, "cancel_turn", %{})
    assert_reply ref, :ok

    assert Enum.any?(
             events_until("conversation.turn.ended"),
             &(&1["payload"]["status"] == "interrupted")
           )

    ref = push(socket, "cancel_turn", %{})
    assert_reply ref, :error, %{"reason" => "no_turn"}

    ref = say(socket, String.duplicate("x", Engine.max_message_bytes() + 1))
    assert_reply ref, :error, %{"reason" => "message_too_large"}

    ref = say(socket, "SAY hi", "not-a-uuid")
    assert_reply ref, :error, %{"reason" => "invalid_message"}

    ref = push(socket, "delete_everything", %{})
    assert_reply ref, :error, %{"reason" => "invalid_request"}
  end

  test "cancel_dispatch cancels only this session's dispatch, as the person's request", ctx do
    socket = join!(ctx)
    binding = %{session_id: ctx.session, repository: ctx.repo}

    {:ok, %{"dispatch_id" => id}} =
      Tools.call(
        "dispatch",
        %{
          "purpose" => "implement",
          "worker" => "codex:gpt-6-luna",
          "title" => "Make add return the sum",
          "brief" => @brief,
          "files" => ["calc.py"]
        },
        binding
      )

    ref = push(socket, "cancel_dispatch", %{"dispatch_id" => id, "reason" => " "})
    assert_reply ref, :error, %{"reason" => "invalid_reason"}

    ref =
      push(socket, "cancel_dispatch", %{"dispatch_id" => Ecto.UUID.generate(), "reason" => "x"})

    assert_reply ref, :error, %{"reason" => "dispatch_not_found"}

    ref = push(socket, "cancel_dispatch", %{"dispatch_id" => id, "reason" => "not needed"})
    assert_reply ref, :ok

    dispatch = Shoestring.Dispatches.get(id)
    assert Shoestring.Dispatches.state(dispatch) == "cancelled"
    {:ok, events} = Trajectory.replay(dispatch.goal_id)
    # The cancellation itself names the person, not the grant.
    assert [%{payload: %{"requested_by" => by}}] =
             Enum.filter(events, &Map.has_key?(&1.payload, "cancellation_id"))
             |> Enum.uniq_by(& &1.payload["cancellation_id"])
             |> Enum.take(1)

    assert by == Shoestring.CLI.WorkLoop.default_human()

    # Another session's socket cannot reach it.
    {:ok, _} = grant("chat-two", ctx.repo)
    {:ok, two} = open("chat-two", ctx.repo)

    start_supervised!(
      Supervisor.child_spec({Engine, {two, @engine_opts}}, restart: :temporary, id: :two)
    )

    {:ok, _, other} =
      subscribe_and_join(
        socket(ChatSocket, nil, %{session_id: "chat-two"}),
        ChatChannel,
        "conversation:chat-two",
        %{}
      )

    ref = push(other, "cancel_dispatch", %{"dispatch_id" => id, "reason" => "mine now"})
    assert_reply ref, :error, %{"reason" => "dispatch_not_found"}
  end

  test "a cancel names a person or the grant, nothing else", ctx do
    {:ok, %{"dispatch_id" => id}} =
      Tools.call(
        "dispatch",
        %{
          "purpose" => "implement",
          "worker" => "codex:gpt-6-luna",
          "title" => "Make add return the sum",
          "brief" => @brief,
          "files" => ["calc.py"]
        },
        %{session_id: ctx.session, repository: ctx.repo}
      )

    dispatch = Shoestring.Dispatches.get(id)

    assert {:error, :non_human_identity} =
             Shoestring.Dispatches.cancel(dispatch, "x", requested_by: "grant:" <> ctx.grant.id)

    assert Shoestring.Dispatches.state(dispatch) == "queued"
  end

  test "an event committed before the backlog is read is left to the backlog", ctx do
    socket = %Phoenix.Socket{
      assigns: %{conversation: ctx.conversation, last: 0, ready: false, snapshot: nil},
      transport_pid: self()
    }

    event = %Trajectory.TrajectoryEvent{sequence: 7, type: "conversation.message.human"}

    assert {:noreply, ^socket} =
             ChatChannel.handle_info({:trajectory_event_committed, event}, socket)

    refute_received %Phoenix.Socket.Message{}

    # Once the backlog is out, an event at or before the last pushed is not repeated.
    ready = %{socket | assigns: %{socket.assigns | ready: true, last: 7}}

    assert {:noreply, ^ready} =
             ChatChannel.handle_info({:trajectory_event_committed, event}, ready)
  end

  test "a client that stops reading is detached instead of queued without bound", ctx do
    socket = join!(ctx)
    events_until("conversation.opened")
    ref = Process.monitor(socket.channel_pid)
    Process.unlink(socket.channel_pid)

    # The test process is this channel's transport: fill its queue.
    for _ <- 1..1_001, do: send(self(), :unread)
    _ = say(socket, "SAY hello")

    assert_push "detached", %{"reason" => "slow_consumer"}, 5_000
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 5_000
  end

  test "at boot, engines start for conversations whose session has a grant", ctx do
    {:ok, _} = open("chat-ungranted", ctx.repo)
    {:ok, granted} = open("chat-granted", ctx.repo)
    {:ok, _} = grant("chat-granted", ctx.repo)

    started = Resume.run(@engine_opts)
    on_exit(fn -> for c <- started, pid = Conversations.engine(c), do: GenServer.stop(pid) end)

    sessions = Enum.map(started, & &1.session_id)
    assert "chat-granted" in sessions
    assert ctx.session in sessions
    refute "chat-ungranted" in sessions
    assert is_pid(Conversations.engine(granted))
    assert Repo.aggregate(Shoestring.Conversations.Conversation, :count) == 3
  end
end
